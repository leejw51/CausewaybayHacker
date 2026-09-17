/**
 * The canvas the coder flies on.
 *
 * The editor is a DOM element over both game canvases (`ui/codefx.ts` has
 * the whole argument), so a sprite that flies *over the code* has to be
 * painted on a layer above it: one transparent 2D canvas inside `#overlay`,
 * added after the editor and after the effects layer, taking no pointer
 * events. It draws in the game's own virtual coordinates by setting the
 * same transform `Layout.begin` does.
 */
import type { Layout } from "../../engine/layout";
import type { Ctx } from "../../engine/ui";

export class AgentLayer {
  private readonly canvas = document.createElement("canvas");
  readonly g: Ctx | null;

  constructor(
    host: HTMLElement,
    private readonly layout: Layout,
  ) {
    this.canvas.className = "cwb-sparks cwb-agent";
    this.g = this.canvas.getContext("2d");
    host.appendChild(this.canvas);
    requestAnimationFrame(() => this.canvas.classList.add("cwb-on"));
  }

  /** Clear and set the virtual transform; the caller draws, then nothing else is needed. */
  begin(): Ctx | null {
    const g = this.g;
    if (!g) return null;
    const { dw, dh, scale, ox, oy } = this.layout;
    if (this.canvas.width !== dw || this.canvas.height !== dh) {
      this.canvas.width = dw;
      this.canvas.height = dh;
    }
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, dw, dh);
    g.setTransform(scale, 0, 0, scale, ox, oy);
    g.imageSmoothingEnabled = false;
    return g;
  }

  destroy(): void {
    this.canvas.remove();
  }
}
