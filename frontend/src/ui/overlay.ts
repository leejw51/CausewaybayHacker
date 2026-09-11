/**
 * A DOM element pinned over a rectangle of the virtual canvas.
 *
 * Two things in this game are genuinely better as DOM than as canvas: the code
 * editor (SPEC §10 is explicit — nobody solves a HackerRank problem in a
 * hand-rolled textarea) and any field a seed phrase gets pasted into. Both need
 * a real caret, a real clipboard and a real IME.
 *
 * They are still *inside* the 16-bit frame: the canvas draws the sunken well,
 * this positions the element exactly over its face, and the element itself is
 * transparent. `layout.toClient` is the same inverse the pointer handling uses,
 * so the two can never disagree about where a virtual pixel is.
 */
import type { Layout } from "../engine/layout";
import type { Rect } from "../engine/ui";

export class Overlay {
  readonly el: HTMLElement;
  private shown = false;

  constructor(
    private readonly host: HTMLElement,
    private readonly layout: Layout,
    el: HTMLElement,
  ) {
    this.el = el;
    el.classList.add("cwb-hidden");
    host.appendChild(el);
  }

  /** Put it over `rect`, in virtual coordinates, and show it. */
  place(rect: Rect, fontPx?: number): void {
    const [x, y, w, h] = rect;
    const [left, top] = this.layout.toClient(x, y);
    const [right, bottom] = this.layout.toClient(x + w, y + h);
    const hostRect = this.host.getBoundingClientRect();
    const s = this.el.style;
    s.left = `${Math.round(left - hostRect.left)}px`;
    s.top = `${Math.round(top - hostRect.top)}px`;
    s.width = `${Math.max(1, Math.round(right - left))}px`;
    s.height = `${Math.max(1, Math.round(bottom - top))}px`;
    if (fontPx !== undefined) {
      // Type inside the overlay is scaled by the same factor as type on the
      // canvas, so the editor does not stay 12px while the panels grow.
      const [, y0] = this.layout.toClient(0, 0);
      const [, y1] = this.layout.toClient(0, fontPx);
      s.fontSize = `${Math.max(9, Math.round(y1 - y0))}px`;
    }
    if (!this.shown) {
      this.el.classList.remove("cwb-hidden");
      this.shown = true;
    }
  }

  hide(): void {
    if (!this.shown) return;
    this.el.classList.add("cwb-hidden");
    this.shown = false;
  }

  destroy(): void {
    this.el.remove();
  }
}
