/**
 * Game text over the editor: the words a hit says.
 *
 * The editor is a DOM element on top of the game canvas, so anything that has
 * to be read *over* it — "-1 HP" at the line that failed, "+10 XP" off the
 * output, the combo badge in the editor's corner — is DOM too, on the same
 * overlay, styled in `style.css` (`.cwb-pop`, `.cwb-combo`). Each pop removes
 * itself when its animation ends; the badge is one element, placed and filled
 * every frame.
 */
import type { Layout } from "../engine/layout";
import type { Rect } from "../engine/ui";

export type PopKind = "hurt" | "xp" | "clear" | "combo" | "info";

export class Popups {
  private readonly badge = document.createElement("div");
  private readonly badgeN = document.createElement("div");
  private readonly badgeBar = document.createElement("div");
  private shownN = -1;

  constructor(
    private readonly host: HTMLElement,
    private readonly layout: Layout,
  ) {
    this.badge.className = "cwb-combo";
    this.badge.setAttribute("aria-hidden", "true");
    this.badgeN.className = "cwb-combo-n";
    const label = document.createElement("div");
    label.className = "cwb-combo-l";
    label.textContent = "COMBO";
    const track = document.createElement("div");
    track.className = "cwb-combo-t";
    this.badgeBar.className = "cwb-combo-b";
    track.appendChild(this.badgeBar);
    this.badge.append(this.badgeN, label, track);
    host.appendChild(this.badge);
  }

  private client(x: number, y: number): [number, number] {
    const [cx, cy] = this.layout.toClient(x, y);
    const r = this.host.getBoundingClientRect();
    return [cx - r.left, cy - r.top];
  }

  /** A word at a point on the page (client px): rises, holds, and goes. */
  popClient(clientX: number, clientY: number, text: string, kind: PopKind): void {
    const r = this.host.getBoundingClientRect();
    this.place(clientX - r.left, clientY - r.top, text, kind);
  }

  /** A word at a virtual point. */
  pop(x: number, y: number, text: string, kind: PopKind): void {
    const [cx, cy] = this.client(x, y);
    this.place(cx, cy, text, kind);
  }

  private place(left: number, top: number, text: string, kind: PopKind): void {
    const el = document.createElement("div");
    el.className = `cwb-pop cwb-pop-${kind}`;
    el.textContent = text;
    el.style.left = `${Math.round(left)}px`;
    el.style.top = `${Math.round(top)}px`;
    el.addEventListener("animationend", () => el.remove(), { once: true });
    // A pop that never animates (no stylesheet, a background tab) still goes.
    setTimeout(() => el.remove(), 4000);
    this.host.appendChild(el);
  }

  /**
   * The combo badge, in the top-right corner of `rect` (virtual): hidden
   * under 5, `left` the share of the window still open, `tier` its heat.
   */
  combo(rect: Rect | null, n: number, left: number, tier: number): void {
    if (!rect || n < 5) {
      this.badge.classList.remove("cwb-on");
      this.shownN = -1;
      return;
    }
    const [x, y] = this.client(rect[0] + rect[2], rect[1]);
    this.badge.style.left = `${Math.round(x)}px`;
    this.badge.style.top = `${Math.round(y)}px`;
    this.badge.dataset.tier = String(Math.min(tier, 4));
    this.badgeBar.style.width = `${Math.round(left * 100)}%`;
    if (n !== this.shownN) {
      this.badgeN.textContent = `x${n}`;
      // The number kicks on every key.
      this.badgeN.classList.remove("cwb-kick");
      void this.badgeN.offsetWidth;
      this.badgeN.classList.add("cwb-kick");
      this.shownN = n;
    }
    this.badge.classList.add("cwb-on");
  }

  destroy(): void {
    this.badge.remove();
    for (const el of this.host.querySelectorAll(".cwb-pop")) el.remove();
  }
}
