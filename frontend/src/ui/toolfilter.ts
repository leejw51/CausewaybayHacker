/**
 * The box at the head of a toolbar that narrows it to the buttons you name.
 *
 * The playground's band and the quest screen's bars grew past twenty buttons,
 * and twenty touch-sized labels were most of the screen they are the tools
 * for. Empty, it shows every button; typed into, only those whose label — or
 * id, so `copy` finds COPY CODE in any language — contains what was typed.
 *
 * One per scene, shared by the framed screen and CODE, so a filter set on one
 * is still set on the other. It is a DOM field laid over a well the canvas
 * draws, like the playground's search box, and Escape empties it.
 */
import type { Layout } from "../engine/layout";
import { well, type Ctx, type Rect } from "../engine/ui";
import { width, type Font } from "../engine/text";
import { onLocale, t } from "../i18n";
import { Overlay } from "./overlay";

export class ToolFilter {
  private readonly el: HTMLInputElement;
  private overlay: Overlay | null = null;
  private readonly offLocale: () => void;
  query = "";

  constructor() {
    const el = document.createElement("input");
    el.type = "text";
    el.className = "cwb-field cwb-name";
    el.spellcheck = false;
    el.autocomplete = "off";
    el.maxLength = 32;
    el.placeholder = t("tools.filter");
    el.addEventListener("input", () => {
      this.query = el.value;
    });
    el.addEventListener("keydown", (ev) => {
      // Handled here: `App` hands keys typed into an overlay to the field,
      // not to the scene, so the scene's ESC-to-leave never sees this one.
      if (ev.key === "Escape") {
        ev.preventDefault();
        this.clear();
        el.blur();
      }
    });
    this.offLocale = onLocale(() => {
      el.placeholder = t("tools.filter");
    });
    this.el = el;
  }

  mount(host: HTMLElement, layout: Layout): void {
    this.overlay?.destroy();
    this.overlay = new Overlay(host, layout, this.el);
    this.overlay.hide();
  }

  clear(): void {
    this.el.value = "";
    this.query = "";
  }

  /** Whether a button stays on the bar. Everything does while it is empty. */
  keeps(item: { id: string; label: string }): boolean {
    const q = this.query.trim().toLowerCase();
    if (q === "") return true;
    return item.label.toLowerCase().includes(q) || item.id.toLowerCase().includes(q);
  }

  filter<T extends { id: string; label: string }>(items: T[]): T[] {
    return items.filter((i) => this.keeps(i));
  }

  /** How wide the box is drawn in a bar set in `f`: room for a short word. */
  width(f: Font): number {
    return Math.round(Math.max(width(f, t("tools.filter")), width(f, "MMMMMMMM")) + f.size * 1.5);
  }

  /** The well and the field over it. */
  draw(g: Ctx, rect: Rect, f: Font): void {
    // Nothing to type into until a scene mounts it — a quest still loading.
    if (!this.overlay) return;
    const [x, y, w, h] = rect;
    well(g, x, y, w, h, [0.06, 0.05, 0.14, 0.98]);
    this.overlay.place([x + 3, y + 3, w - 6, h - 6], f.size);
  }

  hide(): void {
    this.overlay?.hide();
  }

  destroy(): void {
    this.offLocale();
    this.overlay?.destroy();
    this.overlay = null;
  }
}
