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
import { css, Theme, TRACK_COL, type RGBA } from "../engine/theme";
import type { Land } from "../net/protocol";
import { bodyFontAt, ensureFonts, font, printf, width, type Font } from "../engine/text";
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
import { t } from "../i18n";

// One definition per land, taken from the palette rather than restated here.
export const RUST: RGBA = TRACK_COL.rust;
export const GO: RGBA = TRACK_COL.go;

/**
 * A land's own colour, for the accent on every screen that knows its land.
 * The screens used to write `land === "rust" ? RUST : GO`, which was a choice
 * between two lands and silently coloured a third one cyan. Takes a string
 * because a search hit's land arrives untyped, and an unknown one gets Ferris.
 */
/**
 * The land's name as a player reads it.
 *
 * Not `land.toUpperCase()`, which is right for three of the four and wrong for
 * the one that matters: `"cpp"` upper-cases to `CPP`, which is not what anybody
 * calls the language. The catalogue already holds the display name for the
 * plate's own title bar, so every other title takes it from the same place
 * rather than inventing one — the panel beside a plate reading `CPP` while the
 * plate itself reads `C++` is the kind of small disagreement that makes a
 * screen feel unfinished.
 */
export function landName(land: Land | string): string {
  return t(`map.${land}` as "map.rust");
}

export function landColour(land: Land | string): RGBA {
  return TRACK_COL[land] ?? RUST;
}

export interface Frame {
  /** The whole playfield, inset by the safe margin. */
  body: Rect;
  /** Two boxes side by side in landscape, stacked in portrait. */
  left: Rect;
  right: Rect;
  headerH: number;
  footerH: number;
  scale: number;
  /**
   * True when the two boxes are **stacked** rather than side by side.
   *
   * Usually that is the window's orientation, which is why it is called this;
   * a screen that passes `stack` overrides it, and then this says what the
   * layout actually did rather than what the window is. The only consumer is
   * `arriveFrom`, which needs to know which edge a panel comes in from, and
   * that is a fact about the layout and not about the window.
   */
  portrait: boolean;
  pad: number;
}

/**
 * How the two boxes sit relative to each other.
 *
 * `auto` follows the window, which is what every screen wants and what they
 * all did before there was a choice. The quest screen offers the other two to
 * the player, because it is the screen somebody stares at for an hour and a
 * brief beside the editor and a brief above it suit different eyes and
 * different windows — a wide monitor can want the stacked one, and a tall
 * window can want the columns.
 */
export type Stack = "auto" | "row" | "column";

/**
 * `split` is how much of the long axis the first box takes, 0..1. The gap and
 * the margins are in virtual pixels scaled by the UI scale, so they stay the
 * same size to the eye whether the canvas grew or shrank.
 *
 * `reserve` is height taken off the top of the body before the boxes are cut,
 * for a screen that puts a toolbar between the header and its panels. It is a
 * parameter rather than each screen subtracting it afterwards because a box
 * whose height was adjusted after the split is a box whose *contents* were
 * laid out against the wrong height — which is the fault decisions.md records
 * twice as "measure the row before you reserve its height".
 */
export function frame(
  layout: Layout,
  split = 0.5,
  inset = 0,
  stack: Stack = "auto",
  reserve = 0,
): Frame {
  const s = layout.uiScale();
  // `inset` holds the panels off the edges as a fraction of the body, so a
  // screen can let the city breathe around it. The working screens — map and
  // quest — pass nothing and stay full-bleed, because room to read beats
  // room to look.
  const pad = Math.round(10 * s) + Math.round(inset * layout.vw * 0.5);
  const headerH = Math.round(38 * s);
  const footerBar = footerH(layout);
  const x = pad;
  const y = headerH + pad + reserve;
  const w = layout.vw - pad * 2;
  const h = layout.vh - headerH - footerBar - pad * 2 - reserve;
  const portrait = stack === "auto" ? layout.isPortrait() : stack === "column";
  const gap = pad;
  if (portrait) {
    const top = Math.round((h - gap) * split);
    return {
      body: [x, y, w, h],
      left: [x, y, w, top],
      right: [x, y + top + gap, w, h - top - gap],
      headerH,
      footerH: footerBar,
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
    footerH: footerBar,
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
  const label = `${who}  ${t("chrome.logout")}`;
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

/**
 * How tall the footer hint bar is, in virtual pixels.
 *
 * It used to be `26 * s` in six places. That was fine while the hint font was
 * eight pixels of Press Start 2P and could not outgrow it; the moment the small
 * chrome face became VT323 at 20 the keys ran off the bottom of the screen in
 * portrait. The bar is now whatever the line in it needs, and every screen that
 * reserves room for it asks here instead of repeating the number.
 */
export function footerH(layout: Layout): number {
  const s = layout.uiScale();
  return Math.max(Math.round(26 * s), ensureFonts(s).stationSm.height + Math.round(8 * s));
}

/**
 * The key hints along the bottom. Also where F1 is advertised.
 *
 * The line is shrunk to fit rather than wrapped. The bar has a fixed height
 * that several screens reserve room against, so a second row runs off the
 * bottom of the window — which is exactly what a Korean quest screen in
 * portrait did the first time the chrome font grew. Dropping hints off the end
 * instead would be worse: this bar is how a player learns the keyboard, and a
 * hint that is sometimes there teaches nothing.
 */
export function footer(g: Ctx, layout: Layout, hint: string): void {
  const s = layout.uiScale();
  const h = footerH(layout);
  const y = layout.vh - h;
  fill(g, Theme.ink, 0, y, layout.vw, h, 0.85);
  fill(g, Theme.wood, 0, y, layout.vw, 2);
  const full = ensureFonts(s).stationSm;
  const room = layout.vw - Math.round(16 * s);
  let f = full;
  // Down in steps, never below two thirds — past that it is the small type
  // this change existed to get rid of, and a window that narrow has bigger
  // problems than the key hints.
  for (let px = full.size; px >= Math.round(full.size * 0.66); px -= Math.max(1, Math.round(s))) {
    f = bodyFontAt(px);
    if (width(f, hint) <= room) break;
  }
  lastFooterPx = f.size;
  g.fillStyle = css(Theme.dim);
  printf(g, f, hint, 0, y + Math.round((h - f.height) / 2), layout.vw, "center");
}

/**
 * The size the footer line was actually drawn at last frame.
 *
 * Only the capture hook reads it. It exists because the hint bar is the one
 * piece of type on screen whose size is decided at draw time, so "how big is
 * the footer" has no answer anywhere else — and it is one of the two things
 * the size complaint named.
 */
let lastFooterPx = 0;
export function footerFontPx(): number {
  return lastFooterPx;
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
  /** The one action the screen is for. Filled, not outlined. */
  primary?: boolean;
  /** The action that commits. Its own colour, not a louder primary. */
  strong?: boolean;
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
    labels: Array<{
      id: string;
      label: string;
      dim?: boolean;
      primary?: boolean;
      strong?: boolean;
    }>,
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
      this.add({
        id: item.id,
        rect: [cx, cy, bw, bh],
        label: item.label,
        dim: item.dim,
        primary: item.primary,
        strong: item.strong,
      });
      cx += bw + gap;
      lineH = Math.max(lineH, bh);
    }
  }

  draw(g: Ctx, f: Font): void {
    // If the row names a primary action, everything else on it goes quiet.
    const hasPrimary = this.items.some((b) => b.primary);
    for (const b of this.items) {
      pixBtn(g, f, b.rect[0], b.rect[1], b.rect[2], b.rect[3], b.label, {
        hover: this.hovered === b.id,
        dim: b.dim,
        lit: b.primary,
        strong: b.strong,
        quiet: hasPrimary && !b.primary && !b.strong,
      });
    }
  }

  /**
   * What is on screen, for the capture hook.
   *
   * Read-only and rebuilt every frame like the rest of this class. It exists
   * because a canvas button has no DOM node: an e2e run that wants to press
   * SUBMIT has either a list like this or a geometric scan of the pixels, and
   * the scan breaks every time a row re-wraps — which has now cost three runs.
   */
  list(): readonly Button[] {
    return this.items;
  }

  hit(x: number, y: number): Button | null {
    for (const b of this.items) if (!b.dim && inRect(x, y, b.rect)) return b;
    return null;
  }
}

/**
 * Stars **earned**, and nothing else. Three of them, gold.
 *
 * The star glyph is reserved for the score on purpose: difficulty used to be
 * drawn with the same glyph on the same row, and a player reading `★☆☆☆☆` next
 * to `1/3 STARS` has no way to tell that one of those is a property of the
 * street and the other is their own result.
 */
export function stars(g: Ctx, x: number, y: number, r: number, n: number, of = 3): void {
  for (let i = 0; i < of; i++) {
    star(g, x + i * r * 2.4, y, r, i < n ? Theme.coin : Theme.dim);
  }
}

/**
 * Difficulty, which is not a score: a segmented bar in the brick colour, under
 * its own word. A bar cannot be mistaken for a tally of anything the player
 * did, which is the whole reason it is not five stars.
 */
export function difficulty(g: Ctx, x: number, y: number, w: number, n: number, of = 5): void {
  const f = font("stationSm");
  g.fillStyle = css(Theme.dim);
  printf(g, f, t("chrome.difficulty"), x, y, w, "left");
  const by = y + f.height + Math.round(f.size * 0.4);
  const gap = Math.max(2, Math.round(f.size * 0.3));
  const seg = (w - gap * (of - 1)) / of;
  const h = Math.max(4, Math.round(f.size * 0.7));
  for (let i = 0; i < of; i++) {
    const sx = x + i * (seg + gap);
    fill(g, Theme.ink, sx, by, seg, h, 0.7);
    fill(g, i < n ? Theme.brick : Theme.dim, sx + 1, by + 1, seg - 2, h - 2, i < n ? 1 : 0.3);
  }
}

/** How tall `difficulty` draws, so a caller can lay out around it. */
export function difficultyH(): number {
  const f = font("stationSm");
  return f.height + Math.round(f.size * 0.4) + Math.max(4, Math.round(f.size * 0.7));
}

/**
 * A small diagonal ribbon across a map node. The full `CLEARED` stamp is far
 * too wide to read at node size — seven pixel-font characters inside a 28px
 * circle is a smudge — so the node gets a banner and the info plate below gets
 * the stamp.
 */
export function clearRibbon(g: Ctx, cx: number, cy: number, w: number): void {
  const f = font("stationSm");
  const label = t("chrome.clearRibbon");
  const scale = (w * 0.78) / Math.max(1, width(f, label));
  g.save();
  g.translate(cx, cy);
  g.rotate(-0.42);
  g.scale(scale, scale);
  const bw = width(f, label) + f.size;
  const bh = f.height + f.size * 0.5;
  g.fillStyle = css(Theme.ink);
  g.fillRect(-bw / 2 - 2, -bh / 2 - 2, bw + 4, bh + 4);
  // Green, not red. This banner is the payoff of the loop and it used to be
  // painted in the colour that means you failed two screens earlier.
  g.fillStyle = css(Theme.admit);
  g.fillRect(-bw / 2, -bh / 2, bw, bh);
  g.fillStyle = css(Theme.cream);
  printf(g, f, label, -bw / 2, -f.height / 2, bw, "center");
  g.restore();
}

/**
 * The `CLEARED` stamp: the ring from `art/stamp_cleared.png` with the word
 * printed over it at runtime.
 *
 * The word is not baked into the sprite for two reasons. A generator cannot be
 * trusted to spell seven letters, and a printed word can be translated while a
 * painted one cannot. `CausewaybayGolang` does the same thing with
 * `stamp_served`, so the two projects' stamps stay the same object.
 *
 * Green and gold, never red — this is the one moment the whole loop exists to
 * produce.
 */
export function clearedStamp(
  g: Ctx,
  app: App,
  cx: number,
  cy: number,
  w: number,
  angle = -0.18,
): void {
  const f = font("stamp");
  const label = t("chrome.cleared");
  const tw = Math.max(1, width(f, label));
  const ring = app.assets?.picture("stamp_cleared") ?? null;
  g.save();
  g.translate(cx, cy);
  g.rotate(angle);
  if (ring) {
    g.drawImage(ring, -w / 2, -w / 2, w, w);
  } else {
    // No art yet: a drawn ring, so the moment still lands on the first clear
    // of a cold cache rather than showing a bare word.
    g.lineWidth = Math.max(3, w * 0.07);
    g.strokeStyle = css(Theme.coin);
    g.fillStyle = css(Theme.admit, 0.9);
    g.beginPath();
    g.arc(0, 0, w * 0.46, 0, Math.PI * 2);
    g.fill();
    g.stroke();
    g.lineWidth = 1;
  }
  // The word is sized to the ring's inner field, not to the box it is in.
  const scale = (w * 0.6) / tw;
  g.scale(scale, scale);
  g.fillStyle = css(Theme.ink, 0.55);
  printf(g, f, label, -tw / 2 + 2, -f.height / 2 + 2, tw, "center");
  g.fillStyle = css(Theme.cream);
  printf(g, f, label, -tw / 2, -f.height / 2, tw, "center");
  g.restore();
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
 * A label/value column, aligned in pixels rather than in spaces.
 *
 * The obvious way to write `tests   3/5` is to put three spaces in the string,
 * and it holds exactly as long as every label is English and the font is
 * monospaced. It is neither. `compile` is `kompilace` in Czech and `コンパイル`
 * in Japanese, and in VT323 a CJK glyph is close to twice the advance of a
 * Latin one — so a column padded to eight characters is ragged in Czech and
 * nowhere near a column in Korean. Measure the labels, take the widest, and
 * start every value after it.
 *
 * Returns the height used, so the caller can put something underneath.
 */
export function keyRows(
  g: Ctx,
  f: Font,
  rows: readonly (readonly [string, string])[],
  x: number,
  y: number,
  limit: number,
  gap: number,
): number {
  let keyW = 0;
  for (const [k] of rows) keyW = Math.max(keyW, width(f, k));
  // If the labels have eaten the panel there is nothing to align to, and a
  // value pushed off the right edge is worse than a ragged column.
  const off = Math.min(keyW + gap, Math.max(limit * 0.6, limit - gap));
  let dy = y;
  for (const [k, v] of rows) {
    printf(g, f, k, x, dy, off, "left");
    dy += printf(g, f, v, x + off, dy, limit - off, "left") * f.height;
  }
  return dy - y;
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
