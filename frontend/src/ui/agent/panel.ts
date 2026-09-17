/**
 * The AGENT panel: the room, and the setup behind it.
 *
 * Canvas for everything that is read, DOM for the three things that are
 * typed into (the message, the key, the model name), placed by `Overlay`
 * like every other field in the game. Two pages: CHAT — provider tabs, the
 * messages with their photos, the field and the row of verbs — and SETUP —
 * the key, the model, FETCH MODELS and AUTO. The panel draws and hit-tests;
 * what the verbs *do* is the `Coder`'s, handed in as callbacks.
 */
import type { App } from "../../app";
import { elide, ensureFonts, printf, wrap } from "../../engine/text";
import { css, Theme, type RGBA } from "../../engine/theme";
import { btnBox, clipped, fill, inRect, rowsIn, well, type Ctx, type Rect } from "../../engine/ui";
import { Buttons, titledPanel } from "../chrome";
import { Overlay } from "../overlay";
import { t } from "../../i18n";
import {
  maskKey,
  PROVIDER_NAME,
  PROVIDERS,
  readAuto,
  readKey,
  readModel,
  readShown,
  writeAuto,
  writeShown,
  writeKey,
  writeModel,
  writeProvider,
  type Provider,
} from "../../ai/prefs";
import { listModels } from "../../ai/providers";

export interface Item {
  role: "user" | "agent" | "tool" | "tip";
  text: string;
  photoUrl?: string | null;
  at?: string;
  /** The server's id, once it has one; a tab-only line has none. */
  id?: number;
  edited?: boolean;
  /** Still streaming. */
  live?: boolean;
  error?: boolean;
}

export interface Verbs {
  send(text: string): void;
  write(brief: string): void;
  review(): void;
  image(brief: string): void;
  stop(): void;
  clear(): void;
  /** A message's text, changed; and one taken back. By the server's id. */
  edit(id: number, text: string): void;
  delete(id: number): void;
  /** Something for the bubble. */
  note(text: string): void;
}

/** The most messages drawn; the room keeps more, the screen shows the tail. */
const SHOW_MAX = 120;
/** A photo's drawn height, as a share of the panel's width. */
const PHOTO_SHARE = 0.55;

export class Panel {
  open = false;
  mode: "chat" | "setup" = "chat";
  items: Item[] = [];
  /** Lines back from the tail; 0 is live at the bottom. */
  scroll = 0;
  private overflow = 0;
  status = "";
  readonly buttons = new Buttons();
  private readonly fieldEl: HTMLInputElement;
  private readonly keyEl: HTMLInputElement;
  private readonly modelEl: HTMLInputElement;
  private field: Overlay | null = null;
  private keyField: Overlay | null = null;
  private modelField: Overlay | null = null;
  private listRect: Rect = [0, 0, 0, 0];
  /** Where each message was drawn this frame, for a tap to pick one. */
  private rows: Array<{ id: number; top: number; bottom: number; text: boolean }> = [];
  /** The message a tap picked, by id, or null. */
  selected: number | null = null;
  /** The message the field is editing, or null when it is a new one. */
  editing: number | null = null;
  private models: string[] = [];
  private modelsFor: Provider | null = null;
  private fetching = false;
  private readonly photos = new Map<string, HTMLImageElement | null>();

  constructor(
    private readonly app: App,
    private readonly verbs: Verbs,
  ) {
    const field = document.createElement("input");
    field.type = "text";
    field.className = "cwb-field cwb-agent-field";
    field.spellcheck = false;
    field.autocomplete = "off";
    field.maxLength = 2000;
    field.placeholder = t("agent.askHint");
    field.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") {
        ev.preventDefault();
        this.submit();
      } else if (ev.key === "Escape") {
        ev.preventDefault();
        if (this.editing !== null) this.stopEditing();
        else field.blur();
      }
    });
    this.fieldEl = field;

    const key = document.createElement("input");
    key.type = "password";
    key.className = "cwb-field cwb-agent-field";
    key.spellcheck = false;
    key.autocomplete = "off";
    key.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") {
        ev.preventDefault();
        this.saveSetup();
      }
    });
    this.keyEl = key;

    const model = document.createElement("input");
    model.type = "text";
    model.className = "cwb-field cwb-agent-field";
    model.spellcheck = false;
    model.autocomplete = "off";
    model.placeholder = t("agent.modelHint");
    model.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") {
        ev.preventDefault();
        this.saveSetup();
      }
    });
    this.modelEl = model;
  }

  mount(): void {
    this.leave();
    this.field = new Overlay(this.app.overlay, this.app.layout, this.fieldEl);
    this.keyField = new Overlay(this.app.overlay, this.app.layout, this.keyEl);
    this.modelField = new Overlay(this.app.overlay, this.app.layout, this.modelEl);
    this.field.hide();
    this.keyField.hide();
    this.modelField.hide();
  }

  leave(): void {
    this.field?.destroy();
    this.keyField?.destroy();
    this.modelField?.destroy();
    this.field = this.keyField = this.modelField = null;
  }

  /** Nothing of the panel is on screen: put the fields away. */
  hideFields(): void {
    this.field?.hide();
    this.keyField?.hide();
    this.modelField?.hide();
  }

  push(item: Item): void {
    this.items.push(item);
    if (this.items.length > 500) this.items.shift();
    this.scroll = 0;
  }

  private submit(): void {
    const text = this.fieldEl.value;
    if (!text.trim()) return;
    this.fieldEl.value = "";
    if (this.editing !== null) {
      const id = this.editing;
      this.stopEditing();
      this.verbs.edit(id, text);
      return;
    }
    this.verbs.send(text);
  }

  /** Put a message's text in the field, to be sent back as its new text. */
  startEditing(id: number): void {
    const item = this.items.find((i) => i.id === id);
    if (!item) return;
    this.editing = id;
    this.fieldEl.value = item.text;
    this.status = t("agent.editing");
    setTimeout(() => this.fieldEl.focus(), 0);
  }

  stopEditing(): void {
    this.editing = null;
    this.fieldEl.value = "";
    if (this.status === t("agent.editing")) this.status = "";
  }

  private saveSetup(): void {
    const provider = this.provider;
    const key = this.keyEl.value.trim();
    writeKey(provider, key);
    writeModel(provider, this.modelEl.value);
    this.status = key ? t("agent.keySaved") : t("agent.keyCleared");
    this.keyEl.value = key;
    this.app.chip.blip();
  }

  private provider: Provider = "anthropic";

  private async fetchModels(): Promise<void> {
    if (this.fetching) return;
    const provider = this.provider;
    const key = this.keyEl.value.trim() || readKey(provider);
    if (!key) {
      this.status = t("agent.noKey", { provider: PROVIDER_NAME[provider] });
      this.app.chip.fail();
      return;
    }
    this.fetching = true;
    this.status = "…";
    try {
      this.models = await listModels(provider, key);
      this.modelsFor = provider;
      this.status = t("agent.models", { n: this.models.length });
      this.app.chip.blip();
    } catch (e) {
      this.status = t("agent.modelsFailed", {
        why: (e instanceof Error ? e.message : String(e)).slice(0, 80),
      });
      this.app.chip.fail();
    } finally {
      this.fetching = false;
    }
  }

  // -- drawing ---------------------------------------------------------------

  draw(
    g: Ctx,
    rect: Rect,
    s: number,
    ctx: { provider: Provider; busy: boolean; canImage: boolean },
  ): void {
    this.provider = ctx.provider;
    const { layout } = this.app;
    const fonts = ensureFonts(s);
    const f = fonts.stationSm;
    const title = t("agent.provider", {
      name: `${t("agent.title")} · ${PROVIDER_NAME[ctx.provider]}`,
      model: readModel(ctx.provider),
    });
    const inner = titledPanel(g, rect, elide(f, title, rect[2] - 24), Theme.coin, Theme.navy);
    this.buttons.reset();
    const gap = Math.round(5 * s);
    let y = inner[1];

    // Provider tabs, the one with a key lit, and the page switch.
    const tabs = PROVIDERS.map((p) => ({
      id: `prov:${p}`,
      label: PROVIDER_NAME[p],
      strong: p === ctx.provider,
      dim: false,
    }));
    const tail = [
      {
        id: this.mode === "chat" ? "setup" : "chat",
        label: this.mode === "chat" ? t("agent.setup") : t("agent.chat"),
      },
      { id: "close", label: t("agent.close") },
    ];
    const rowItems = [...tabs, ...tail];
    const [, bh] = btnBox(
      f,
      rowItems.map((i) => i.label),
      0,
      f.size * 2,
      layout.minTouchH(),
    );
    const rows = rowsIn(
      f,
      rowItems.map((i) => i.label),
      inner[2],
      layout.minTouchH(),
    );
    const rowGap = Math.round(f.size * 0.5);
    this.buttons.row(f, [inner[0], y, inner[2], 0], rowItems, layout.minTouchH());
    y += rows * bh + (rows - 1) * rowGap + gap;

    if (this.mode === "setup") {
      this.field?.hide();
      this.drawSetup(g, [inner[0], y, inner[2], inner[1] + inner[3] - y], s);
    } else {
      this.keyField?.hide();
      this.modelField?.hide();
      this.drawChat(g, [inner[0], y, inner[2], inner[1] + inner[3] - y], s, ctx);
    }
    this.buttons.draw(g, f);
  }

  private drawSetup(g: Ctx, rect: Rect, s: number): void {
    const { layout } = this.app;
    const fonts = ensureFonts(s);
    const f = fonts.stationSm;
    const body = fonts.small;
    const gap = Math.round(6 * s);
    const provider = this.provider;
    let y = rect[1];
    const fieldH = Math.max(layout.minTouchH(), body.height + Math.round(12 * s));

    // Populate the fields when the page is first shown for this provider.
    if (this.keyEl.dataset.for !== provider) {
      this.keyEl.dataset.for = provider;
      this.keyEl.value = readKey(provider);
      this.modelEl.value = readModel(provider);
      this.keyEl.placeholder = t("agent.keyHint", { provider: PROVIDER_NAME[provider] });
    }

    g.fillStyle = css(Theme.cream, 0.8);
    const stored = readKey(provider);
    printf(
      g,
      body,
      elide(
        body,
        stored
          ? `${PROVIDER_NAME[provider]} · ${maskKey(stored)}`
          : t("agent.noKey", { provider: PROVIDER_NAME[provider] }),
        rect[2],
      ),
      rect[0],
      y,
      rect[2],
      "left",
    );
    y += body.height + gap;
    well(g, rect[0], y, rect[2], fieldH, [0.06, 0.05, 0.14, 0.98]);
    this.keyField?.place([rect[0] + 4, y + 3, rect[2] - 8, fieldH - 6], body.size);
    y += fieldH + gap;
    well(g, rect[0], y, rect[2], fieldH, [0.06, 0.05, 0.14, 0.98]);
    this.modelField?.place([rect[0] + 4, y + 3, rect[2] - 8, fieldH - 6], body.size);
    y += fieldH + gap;

    const auto = readAuto();
    const items = [
      { id: "savekey", label: t("agent.save"), primary: true },
      { id: "fetch", label: t("agent.fetchModels"), dim: this.fetching },
      { id: "auto", label: t("agent.auto"), strong: auto },
      // The character itself, on or off. The verbs do not depend on it.
      { id: "coder", label: readShown() ? t("agent.coderOn") : t("agent.coderOff") },
    ];
    const [, bh] = btnBox(
      f,
      items.map((i) => i.label),
      0,
      f.size * 2,
      layout.minTouchH(),
    );
    const rows = rowsIn(
      f,
      items.map((i) => i.label),
      rect[2],
      layout.minTouchH(),
    );
    this.buttons.row(f, [rect[0], y, rect[2], 0], items, layout.minTouchH());
    y += rows * bh + (rows - 1) * Math.round(f.size * 0.5) + gap;

    g.fillStyle = css(Theme.dim);
    const note = this.status || (auto ? t("agent.autoOn") : t("agent.autoOff"));
    const noteLines = wrap(body, note, rect[2]).slice(0, 3);
    for (const line of noteLines) {
      printf(g, body, line, rect[0], y, rect[2], "left");
      y += body.height;
    }
    y += gap;

    // The models, if fetched for this provider: a clickable column.
    if (this.modelsFor === provider && this.models.length) {
      const rowH = Math.max(layout.minTouchH(), body.height + Math.round(6 * s));
      const room = rect[1] + rect[3] - y;
      const current = this.modelEl.value.trim();
      clipped(g, rect[0], y, rect[2], Math.max(0, room), () => {
        let ry = y;
        for (const id of this.models) {
          if (ry + rowH > y + room) break;
          const on = id === current;
          const hover = this.buttons.hovered === `model:${id}`;
          fill(g, on ? Theme.navy : Theme.ink, rect[0], ry, rect[2], rowH - 2, on ? 0.95 : 0.5);
          g.fillStyle = css(on ? Theme.coin : Theme.cream, hover ? 1 : 0.85);
          printf(
            g,
            body,
            elide(body, id, rect[2] - 12),
            rect[0] + 6,
            ry + Math.round((rowH - body.height) / 2),
            rect[2] - 12,
            "left",
          );
          this.buttons.add({
            id: `model:${id}`,
            rect: [rect[0], ry, rect[2], rowH - 2],
            label: id,
            painted: true,
          });
          ry += rowH;
        }
      });
    }
  }

  private drawChat(
    g: Ctx,
    rect: Rect,
    s: number,
    ctx: { provider: Provider; busy: boolean; canImage: boolean },
  ): void {
    const { layout } = this.app;
    const fonts = ensureFonts(s);
    const f = fonts.stationSm;
    const body = fonts.small;
    const gap = Math.round(5 * s);
    const fieldH = Math.max(layout.minTouchH(), body.height + Math.round(12 * s));

    // The verbs, at the foot, measured first.
    const picked = this.selected === null ? null : this.rows.find((r) => r.id === this.selected);
    const pickedItem =
      this.selected === null ? null : this.items.find((i) => i.id === this.selected);
    const items = [
      { id: "send", label: t("agent.send"), primary: !ctx.busy, dim: ctx.busy },
      // A picked message can be changed or taken back — a messenger's two
      // verbs. EDIT only on text, and only while nothing else is in the field.
      ...(pickedItem && picked
        ? [
            ...(pickedItem.photoUrl
              ? []
              : [
                  {
                    id: "editmsg",
                    label: t("agent.edit"),
                    dim: ctx.busy,
                    strong: this.editing !== null,
                  },
                ]),
            { id: "deletemsg", label: t("agent.delete"), dim: ctx.busy },
          ]
        : []),
      { id: "write", label: t("agent.write"), dim: ctx.busy },
      { id: "review", label: t("agent.review"), dim: ctx.busy },
      ...(ctx.canImage ? [{ id: "image", label: t("agent.image"), dim: ctx.busy }] : []),
      { id: "stop", label: t("agent.stop"), dim: !ctx.busy, strong: ctx.busy },
      { id: "clearroom", label: t("agent.clear"), dim: ctx.busy },
    ];
    const [, bh] = btnBox(
      f,
      items.map((i) => i.label),
      0,
      f.size * 2,
      layout.minTouchH(),
    );
    const rows = rowsIn(
      f,
      items.map((i) => i.label),
      rect[2],
      layout.minTouchH(),
    );
    const rowGap = Math.round(f.size * 0.5);
    const bandH = rows * bh + (rows - 1) * rowGap;
    const bandY = rect[1] + rect[3] - bandH;
    this.buttons.row(f, [rect[0], bandY, rect[2], 0], items, layout.minTouchH());

    // The status line over the verbs, then the field over that.
    const statusH = this.status ? body.height + gap : 0;
    const fieldY = bandY - gap - statusH - fieldH;
    if (this.status) {
      g.fillStyle = css(Theme.coin, 0.9);
      printf(
        g,
        body,
        elide(body, this.status, rect[2]),
        rect[0],
        fieldY + fieldH + gap,
        rect[2],
        "left",
      );
    }
    well(g, rect[0], fieldY, rect[2], fieldH, [0.06, 0.05, 0.14, 0.98]);
    this.field?.place([rect[0] + 4, fieldY + 3, rect[2] - 8, fieldH - 6], body.size);

    // The room.
    const listH = fieldY - gap - rect[1];
    this.listRect = [rect[0], rect[1], rect[2], Math.max(0, listH)];
    well(g, rect[0], rect[1], rect[2], Math.max(0, listH), [0.05, 0.04, 0.12, 0.9]);
    const pad = Math.round(6 * s);
    const innerX = rect[0] + pad;
    const innerW = rect[2] - pad * 2;
    // Laid out bottom-up from the tail, so the newest is always in view and
    // `scroll` walks back into the past — the console's own convention.
    type Line =
      | { kind: "text"; text: string; color: RGBA; font: typeof body; id?: number }
      | { kind: "photo"; url: string; h: number; id?: number }
      | { kind: "gap"; h: number };
    const lines: Line[] = [];
    const shown = this.items.slice(-SHOW_MAX);
    if (shown.length === 0) {
      for (const l of wrap(body, t("agent.empty"), innerW))
        lines.push({ kind: "text", text: l, color: Theme.dim, font: body });
    }
    for (const item of shown) {
      const tag =
        item.role === "user"
          ? t("agent.you")
          : item.role === "tool"
            ? t("agent.tool")
            : item.role === "tip"
              ? t("agent.tip")
              : PROVIDER_NAME[ctx.provider];
      const tagColor =
        item.role === "user"
          ? Theme.cyan
          : item.role === "tool"
            ? item.error
              ? Theme.red
              : Theme.dim
            : Theme.coin;
      lines.push({ kind: "gap", h: Math.round(4 * s) });
      const label = item.edited ? `${tag} · ${t("agent.edited")}` : tag;
      lines.push({ kind: "text", text: label, color: tagColor, font: f, id: item.id });
      const color = item.role === "tool" ? (item.error ? Theme.red : Theme.dim) : Theme.cream;
      const text = item.live ? `${item.text}▌` : item.text;
      for (const l of wrap(body, text || " ", innerW))
        lines.push({ kind: "text", text: l, color, font: body, id: item.id });
      if (item.photoUrl)
        lines.push({
          kind: "photo",
          url: item.photoUrl,
          h: Math.round(innerW * PHOTO_SHARE),
          id: item.id,
        });
    }
    const heightOf = (l: Line) => (l.kind === "text" ? l.font.height : l.h);
    const total = lines.reduce((n, l) => n + heightOf(l), 0);
    const room = Math.max(0, listH - pad * 2);
    this.overflow = Math.max(0, total - room);
    this.scroll = Math.max(0, Math.min(this.scroll, this.overflow));
    this.rows = [];
    clipped(g, rect[0] + 4, rect[1] + 4, rect[2] - 8, Math.max(0, listH - 8), () => {
      // The bottom of the last line sits at the bottom of the well, moved
      // down by `scroll` so earlier lines come into view.
      let y = rect[1] + pad + room - total + this.scroll;
      for (const l of lines) {
        const h = heightOf(l);
        // The span each server-backed message covers, for a tap; and the
        // picked one lit behind its lines.
        if (l.kind !== "gap" && l.id !== undefined) {
          const last = this.rows[this.rows.length - 1];
          if (last && last.id === l.id) last.bottom = y + h;
          else this.rows.push({ id: l.id, top: y, bottom: y + h, text: l.kind === "text" });
          if (l.id === this.selected) fill(g, Theme.coin, rect[0] + 4, y, rect[2] - 8, h, 0.14);
        }
        if (y + h >= rect[1] && y <= rect[1] + listH) {
          if (l.kind === "text") {
            g.fillStyle = css(l.color);
            printf(g, l.font, l.text, innerX, y, innerW, "left");
          } else if (l.kind === "photo") {
            const img = this.photo(l.url);
            if (img && img.naturalWidth > 0) {
              const k = Math.min(innerW / img.naturalWidth, l.h / img.naturalHeight);
              const w = img.naturalWidth * k;
              const hh = img.naturalHeight * k;
              fill(g, Theme.ink, innerX - 2, y - 2 + (l.h - hh) / 2, w + 4, hh + 4);
              g.drawImage(img, innerX, y + (l.h - hh) / 2, w, hh);
            } else {
              fill(g, Theme.ink, innerX, y, innerW, l.h, 0.6);
              g.fillStyle = css(Theme.dim);
              printf(g, body, "…", innerX, y + l.h / 2 - body.height / 2, innerW, "center");
            }
          }
        }
        y += h;
      }
    });
    this.registerRows(rect, listH);
  }

  /**
   * Every message's span as a painted button, `msg:<id>`, cut to the well.
   * A tap on one picks it, and — the reason it is a button and not a private
   * hit test — an automated run can find and press it like any control.
   */
  private registerRows(rect: Rect, listH: number): void {
    const top = rect[1] + 4;
    const bottom = rect[1] + Math.max(0, listH) - 4;
    for (const r of this.rows) {
      const y0 = Math.max(top, r.top);
      const y1 = Math.min(bottom, r.bottom);
      if (y1 <= y0) continue;
      this.buttons.add({
        id: `msg:${r.id}`,
        rect: [rect[0] + 4, y0, rect[2] - 8, y1 - y0],
        label: "",
        painted: true,
      });
    }
  }

  private photo(url: string): HTMLImageElement | null {
    const hit = this.photos.get(url);
    if (hit !== undefined) return hit;
    const img = new Image();
    img.decoding = "async";
    img.onerror = () => this.photos.set(url, null);
    img.src = url;
    this.photos.set(url, img);
    return img;
  }

  // -- input -----------------------------------------------------------------

  pointer(x: number, y: number, phase: "down" | "move" | "up"): boolean {
    if (!this.open) return false;
    if (phase === "move") {
      const hit = this.buttons.hit(x, y);
      this.buttons.hovered = hit?.id ?? null;
      return hit !== null;
    }
    if (phase !== "down") return false;
    const hit = this.buttons.hit(x, y);
    if (!hit) {
      if (!inRect(x, y, this.listRect)) return false;
      // A tap on nothing lets go of whatever was picked.
      if (this.selected !== null) {
        this.selected = null;
        if (this.editing !== null) this.stopEditing();
      }
      return true;
    }
    const id = hit.id;
    if (id.startsWith("msg:")) {
      // A tap on a message picks it; on the picked one, lets go.
      const picked = Number(id.slice(4));
      const next = picked === this.selected ? null : picked;
      this.selected = next;
      if (this.editing !== null && this.editing !== next) this.stopEditing();
      this.app.chip.blip();
      return true;
    }
    if (id.startsWith("prov:")) {
      const p = id.slice(5) as Provider;
      writeProvider(p);
      this.provider = p;
      this.keyEl.dataset.for = "";
      this.status = "";
      this.app.chip.blip();
      return true;
    }
    if (id.startsWith("model:")) {
      this.modelEl.value = id.slice(6);
      writeModel(this.provider, this.modelEl.value);
      this.app.chip.blip();
      return true;
    }
    switch (id) {
      case "setup":
        this.mode = "setup";
        this.status = "";
        break;
      case "chat":
        this.mode = "chat";
        this.status = "";
        break;
      case "close":
        this.open = false;
        this.hideFields();
        break;
      case "send":
        this.submit();
        break;
      case "write": {
        const b = this.fieldEl.value;
        this.fieldEl.value = "";
        this.verbs.write(b);
        break;
      }
      case "review":
        this.verbs.review();
        break;
      case "image": {
        const b = this.fieldEl.value;
        this.fieldEl.value = "";
        this.verbs.image(b);
        break;
      }
      case "stop":
        this.verbs.stop();
        break;
      case "clearroom":
        this.selected = null;
        this.stopEditing();
        this.verbs.clear();
        break;
      case "editmsg":
        if (this.selected !== null) {
          if (this.editing === this.selected) this.stopEditing();
          else this.startEditing(this.selected);
        }
        break;
      case "deletemsg":
        if (this.selected !== null) {
          const id = this.selected;
          this.selected = null;
          if (this.editing === id) this.stopEditing();
          this.verbs.delete(id);
        }
        break;
      case "savekey":
        this.saveSetup();
        break;
      case "fetch":
        void this.fetchModels();
        break;
      case "coder": {
        writeShown(!readShown());
        this.status = readShown() ? t("agent.coderShown") : t("agent.coderHidden");
        this.app.chip.blip();
        break;
      }
      case "auto": {
        const on = !readAuto();
        writeAuto(on);
        this.status = on ? t("agent.autoOn") : t("agent.autoOff");
        this.app.chip.blip();
        break;
      }
      default:
        return false;
    }
    this.app.chip.select();
    return true;
  }

  wheel(dy: number, x: number, y: number): boolean {
    if (!this.open || this.mode !== "chat" || !inRect(x, y, this.listRect)) return false;
    this.scroll = Math.max(0, Math.min(this.overflow, this.scroll - Math.round(dy)));
    return true;
  }

  key(name: string, ev: KeyboardEvent): boolean {
    if (!this.open) return false;
    // Ctrl/Cmd+Shift+A — the one accelerator, from anywhere: focus the field.
    if (name === "a" && (ev.ctrlKey || ev.metaKey) && ev.shiftKey) {
      ev.preventDefault();
      this.mode = "chat";
      setTimeout(() => this.fieldEl.focus(), 0);
      return true;
    }
    return false;
  }

  /** Whether the field has the caret, so the screen leaves its keys alone. */
  get focused(): boolean {
    return (
      document.activeElement === this.fieldEl ||
      document.activeElement === this.keyEl ||
      document.activeElement === this.modelEl
    );
  }
}
