/**
 * The furniture every screen shares, and the one piece of layout logic worth
 * having in one place: `frame()`.
 *
 * Both orientations are first-class (SPEC §10), and the way that is kept true
 * without writing each screen twice is that every screen asks for a *stack of
 * boxes* rather than positioning things itself. In landscape the stack is two
 * columns; in portrait it is one, taller. A screen that only ever draws into
 * the boxes it is handed cannot be landscape-only by accident.
 */
import { css, Theme, type RGBA } from "../engine/theme";
import { ensureFonts, font, printf, width, type Font } from "../engine/text";
import {
  btnBox,
  fill,
  inRect,
  panel,
  pixBtn,
  shadowText,
  star,
  type Ctx,
  type Rect,
} from "../engine/ui";
import type { Layout } from "../engine/layout";
import type { App } from "../app";
import type { Tween } from "../engine/motion";

export const RUST: RGBA = [0.95, 0.47, 0.16, 1];
export const GO: RGBA = Theme.cyan;

export interface Frame {
  /** The whole playfield, inset by the safe margin. */
  body: Rect;
  /** Two boxes side by side in landscape, stacked in portrait. */
  left: Rect;
  right: Rect;
  headerH: number;
  footerH: number;
  scale: number;
  portrait: boolean;
  pad: number;
}

/**
 * `split` is how much of the long axis the first box takes, 0..1. The gap and
 * the margins are in virtual pixels scaled by the UI scale, so they stay the
 * same size to the eye whether the canvas grew or shrank.
 */
export function frame(layout: Layout, split = 0.5, inset = 0): Frame {
  const s = layout.uiScale();
  // `inset` holds the panels off the edges as a fraction of the body, so a
  // screen can let the city breathe around it. The working screens — map and
  // quest — pass nothing and stay full-bleed, because room to read beats
  // room to look.
  const pad = Math.round(10 * s) + Math.round(inset * layout.vw * 0.5);
  const headerH = Math.round(38 * s);
  const footerH = Math.round(26 * s);
  const x = pad;
  const y = headerH + pad;
  const w = layout.vw - pad * 2;
  const h = layout.vh - headerH - footerH - pad * 2;
  const portrait = layout.isPortrait();
  const gap = pad;
  if (portrait) {
    const top = Math.round((h - gap) * split);
    return {
      body: [x, y, w, h],
      left: [x, y, w, top],
      right: [x, y + top + gap, w, h - top - gap],
      headerH,
      footerH,
      scale: s,
      portrait,
      pad,
    };
  }
  const lw = Math.round((w - gap) * split);
  return {
    body: [x, y, w, h],
    left: [x, y, lw, h],
    right: [x + lw + gap, y, w - lw - gap, h],
    headerH,
    footerH,
    scale: s,
    portrait,
    pad,
  };
}

/**
 * The status bar: where you are on the left, who you are on the right — and
 * the way out.
 *
 * The address doubles as the logout control. That is not a trick: the wallet
 * *is* the account (SPEC §3), so "the thing showing who you are" and "the
 * thing that stops being you" are the same object, and putting LOG OUT
 * somewhere else would mean inventing a settings screen for one verb. It
 * registers its own hit box on `App`, so no scene has to remember to wire it.
 */
export function header(g: Ctx, app: App, title: string): void {
  const { layout } = app;
  const s = layout.uiScale();
  const h = Math.round(38 * s);
  fill(g, Theme.navy, 0, 0, layout.vw, h);
  fill(g, Theme.coin, 0, h - 3, layout.vw, 3);
  fill(g, Theme.ink, 0, h - 1, layout.vw, 1);
  const f = ensureFonts(s).station;
  const ty = Math.round((h - 3 - f.height) / 2);
  g.fillStyle = css(Theme.cream);
  printf(g, f, title, Math.round(8 * s), ty, layout.vw, "left");

  app.logoutRect = null;
  if (!app.addressLabel) return;

  const sm = ensureFonts(s).stationSm;
  // The address is abbreviated because the full forty hex characters is not
  // information anybody reads — the ends are what you check against a wallet.
  const who = `${app.addressLabel.slice(0, 6)}…${app.addressLabel.slice(-4)}`;
  const label = `${who}  LOG OUT`;
  const pad = Math.round(8 * s);
  const w = width(sm, label) + pad * 2;
  const bx = layout.vw - w - Math.round(6 * s);
  const by = Math.round((h - 3 - sm.height) / 2) - Math.round(4 * s);
  const bh = sm.height + Math.round(8 * s);
  const hot = app.logoutHover;
  fill(g, hot ? Theme.red : Theme.ink, bx, by, w, bh, hot ? 0.95 : 0.5);
  fill(g, hot ? Theme.coin : Theme.dim, bx, by + bh - 2, w, 2);
  g.fillStyle = css(hot ? Theme.cream : Theme.cyan);
  printf(g, sm, label, bx, by + Math.round(4 * s), w, "center");
  app.logoutRect = [bx, by, w, bh];
}

/** The key hints along the bottom. Also where F1 is advertised. */
export function footer(g: Ctx, layout: Layout, hint: string): void {
  const s = layout.uiScale();
  const h = Math.round(26 * s);
  const y = layout.vh - h;
  fill(g, Theme.ink, 0, y, layout.vw, h, 0.85);
  fill(g, Theme.wood, 0, y, layout.vw, 2);
  const f = ensureFonts(s).stationSm;
  g.fillStyle = css(Theme.dim);
  printf(g, f, hint, 0, y + Math.round((h - f.height) / 2), layout.vw, "center");
}

/**
 * A click target with a label. Screens build a list of these each frame and
 * hit-test against it, which keeps the drawing and the hit box from drifting
 * apart — the classic way a button ends up unclickable in one orientation.
 */
export interface Button {
  id: string;
  rect: Rect;
  label: string;
  dim?: boolean;
}

export class Buttons {
  private readonly items: Button[] = [];
  hovered: string | null = null;

  reset(): void {
    this.items.length = 0;
  }

  add(b: Button): Button {
    this.items.push(b);
    return b;
  }

  /** Lay a row of buttons out inside `rect`, wrapping to the next line. */
  row(
    f: Font,
    rect: Rect,
    labels: Array<{ id: string; label: string; dim?: boolean }>,
    minH = 0,
  ): void {
    const [x, y, w] = rect;
    const gap = Math.round(f.size * 0.5);
    let cx = x;
    let cy = y;
    let lineH = 0;
    for (const item of labels) {
      const [bw, bh] = btnBox(f, [item.label], 0, f.size * 2, minH);
      if (cx > x && cx + bw > x + w) {
        cx = x;
        cy += lineH + gap;
        lineH = 0;
      }
      this.add({ id: item.id, rect: [cx, cy, bw, bh], label: item.label, dim: item.dim });
      cx += bw + gap;
      lineH = Math.max(lineH, bh);
    }
  }

  draw(g: Ctx, f: Font): void {
    for (const b of this.items) {
      pixBtn(g, f, b.rect[0], b.rect[1], b.rect[2], b.rect[3], b.label, {
        hover: this.hovered === b.id,
        dim: b.dim,
      });
    }
  }

  hit(x: number, y: number): Button | null {
    for (const b of this.items) if (!b.dim && inRect(x, y, b.rect)) return b;
    return null;
  }
}

/** Difficulty, as the map draws it: filled stars up to `n` of five. */
export function stars(g: Ctx, x: number, y: number, r: number, n: number, of = 3): void {
  for (let i = 0; i < of; i++) {
    star(g, x + i * r * 2.4, y, r, i < n ? Theme.coin : Theme.dim);
  }
}

/**
 * A small diagonal ribbon across a map node. The full `CLEARED` stamp is far
 * too wide to read at node size — seven pixel-font characters inside a 28px
 * circle is a smudge — so the node gets a banner and the info plate below gets
 * the stamp.
 */
export function clearRibbon(g: Ctx, cx: number, cy: number, w: number): void {
  const f = font("stationSm");
  const label = "CLEAR";
  const scale = (w * 0.78) / Math.max(1, width(f, label));
  g.save();
  g.translate(cx, cy);
  g.rotate(-0.42);
  g.scale(scale, scale);
  const bw = width(f, label) + f.size;
  const bh = f.height + f.size * 0.5;
  g.fillStyle = css(Theme.ink);
  g.fillRect(-bw / 2 - 2, -bh / 2 - 2, bw + 4, bh + 4);
  g.fillStyle = css(Theme.red);
  g.fillRect(-bw / 2, -bh / 2, bw, bh);
  g.fillStyle = css(Theme.cream);
  printf(g, f, label, -bw / 2, -f.height / 2, bw, "center");
  g.restore();
}

/**
 * The `CLEARED` stamp: rotated, slightly off-square, with the ink ring around
 * it. Drawn rather than blitted so it can be any size it is given.
 */
export function clearedStamp(g: Ctx, cx: number, cy: number, w: number, angle = -0.18): void {
  const f = font("stamp");
  const label = "CLEARED";
  const tw = width(f, label);
  const scale = (w * 0.82) / Math.max(1, tw);
  g.save();
  g.translate(cx, cy);
  g.rotate(angle);
  g.scale(scale, scale);
  const bw = tw + f.size * 1.2;
  const bh = f.height + f.size * 0.9;
  g.lineWidth = Math.max(3, f.size * 0.22);
  g.strokeStyle = css(Theme.red, 0.92);
  g.strokeRect(-bw / 2, -bh / 2, bw, bh);
  g.strokeRect(
    -bw / 2 + g.lineWidth * 1.6,
    -bh / 2 + g.lineWidth * 1.6,
    bw - g.lineWidth * 3.2,
    bh - g.lineWidth * 3.2,
  );
  g.fillStyle = css(Theme.red, 0.92);
  printf(g, f, label, -bw / 2, -f.height / 2, bw, "center");
  g.restore();
  g.lineWidth = 1;
}

/** A titled panel with its face inset returned, so callers draw inside it. */
export function titledPanel(
  g: Ctx,
  rect: Rect,
  title: string,
  accent: RGBA = Theme.coin,
  face: RGBA = Theme.paper,
): Rect {
  const [x, y, w, h] = rect;
  panel(g, x, y, w, h, face);
  const f = font("stationSm");
  const barH = f.height + Math.round(f.size * 0.9);
  fill(g, accent, x + 6, y + 8, w - 12, barH);
  fill(g, Theme.ink, x + 6, y + 8 + barH, w - 12, 1);
  g.fillStyle = css(Theme.ink);
  printf(g, f, title, x + 6, y + 8 + Math.round((barH - f.height) / 2), w - 12, "center");
  const inset = 8;
  return [x + 6 + inset, y + 8 + barH + inset, w - 12 - inset * 2, h - 14 - barH - inset * 2];
}

/**
 * Where a panel is while it is still arriving, in virtual pixels.
 *
 * Panels come in from the edge they are nearest — left box from the left,
 * right box from the right, and in portrait top from the top and bottom from
 * the bottom. Coming from the outside is what makes them read as part of the
 * furniture sliding into place; anything that grows out of the middle reads as
 * a popup, which is a different kind of object with different rules.
 */
export function arriveFrom(f: Frame, which: "left" | "right", t: Tween): [number, number] {
  const k = 1 - t.out;
  if (k <= 0.0005) return [0, 0];
  const reach = f.portrait ? f.body[3] * 0.5 : f.body[2] * 0.6;
  const sign = which === "left" ? -1 : 1;
  return f.portrait ? [0, sign * reach * k] : [sign * reach * k, 0];
}

/** Run `body` translated, for a panel that has not finished arriving. */
export function arriving(g: Ctx, f: Frame, which: "left" | "right", t: Tween, body: () => void) {
  const [dx, dy] = arriveFrom(f, which, t);
  if (dx === 0 && dy === 0) return body();
  g.save();
  g.globalAlpha = Math.min(1, t.raw * 2.2);
  g.translate(Math.round(dx), Math.round(dy));
  body();
  g.restore();
}

export { shadowText };
