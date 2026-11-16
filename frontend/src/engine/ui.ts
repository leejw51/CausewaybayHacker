// Ported from CausewaybayGolang/typescript/src/engine/ui.ts (which in turn
// carries it over from that project's love2d Lua). Kept close to the original
// so a fix made there can still be read across; Causewaybay Hacker changes are
// marked where they occur.
/**
 * Wonder Boy / SNES chrome: a thick gold rim, wood, and a cream or navy fill.
 * `love2d/src/ui.lua`, plus the small drawing helpers `game.lua` keeps to
 * itself — the pixel button, the star and the outlined caption.
 */
import { css, RGBA, Theme } from "./theme";
import { Font, inkCentreY, print, printf, width } from "./text";

export type Ctx = CanvasRenderingContext2D;
export type Rect = readonly [number, number, number, number];

export function fill(g: Ctx, col: RGBA, x: number, y: number, w: number, h: number, a?: number) {
  g.fillStyle = css(col, a);
  g.fillRect(x, y, w, h);
}

export function roundRect(
  g: Ctx,
  x: number,
  y: number,
  w: number,
  h: number,
  r = 8,
): void {
  const rr = Math.max(0, Math.min(r, w * 0.5, h * 0.5));
  g.beginPath();
  g.moveTo(x + rr, y);
  g.arcTo(x + w, y, x + w, y + h, rr);
  g.arcTo(x + w, y + h, x, y + h, rr);
  g.arcTo(x, y + h, x, y, rr);
  g.arcTo(x, y, x + w, y, rr);
  g.closePath();
}

/**
 * The raised panel, in the redesign's glass: a rounded plate of `face` with a
 * thin edge of light. The frame it replaces (ink, gold rim, wood) took eight
 * pixels above the face and six below; callers still lay their content
 * inside those insets, so the plate fills the whole rect and the insets are
 * now simply margin.
 */
export function panel(
  g: Ctx,
  x: number,
  y: number,
  w: number,
  h: number,
  face: RGBA = Theme.panel,
): void {
  const r = Math.max(4, Math.min(12, Math.round(Math.min(w, h) * 0.12)));
  g.save();
  roundRect(g, x, y, w, h, r);
  g.fillStyle = css(face);
  g.fill();
  // A soft light along the top edge, inside: the glass's only bevel.
  g.clip();
  g.fillStyle = "rgba(255,255,255,0.06)";
  g.fillRect(x, y, w, Math.max(1, Math.round(h * 0.08)));
  g.restore();
  g.save();
  g.strokeStyle = css(Theme.cyan, 0.28);
  g.lineWidth = 1;
  roundRect(g, x + 0.5, y + 0.5, w - 1, h - 1, r);
  g.stroke();
  g.restore();
}

/** The sunken well the code and the prompt sit in. */
export function well(
  g: Ctx,
  x: number,
  y: number,
  w: number,
  h: number,
  face: RGBA = [0.1, 0.08, 0.2, 0.98],
): void {
  // Sunken, in the glass: a darker rounded plate with a faint edge.
  const r = Math.max(3, Math.min(10, Math.round(Math.min(w, h) * 0.1)));
  g.save();
  roundRect(g, x, y, w, h, r);
  g.fillStyle = css(face);
  g.fill();
  g.strokeStyle = css(Theme.cyan, 0.16);
  g.lineWidth = 1;
  roundRect(g, x + 0.5, y + 0.5, w - 1, h - 1, r);
  g.stroke();
  g.restore();
}

/** The status bar across the top of a street. */
export function bar(g: Ctx, x: number, y: number, w: number, h: number): void {
  fill(g, [0.06, 0.09, 0.24, 1], x, y, w, h, 0.94);
  fill(g, Theme.cyan, x, y + h - 1, w, 1, 0.25);
}

/** `UI.panel`'s frame: eight pixels of it above the face, six below. */
export const BTN_FRAME = 14;
const BTN_AIR = 6;

/**
 * A button box that fits every one of `labels`. The desktop build measures
 * where a label's ink really lands, because Press Start 2P fills its em from
 * the top while its CJK fallback hangs below the baseline and a button sized
 * from the Latin metrics clips Korean. The browser gives us the same answer
 * from the font's own line box, which `text.ts` already uses as the height.
 */
/**
 * The side padding of a button, both sides together. It was twice the font
 * size — 48 pixels of air around every label at the default size, and in a
 * band of fifteen buttons that air was a whole extra row. One and a quarter
 * still keeps the label clear of the bevel.
 */
export function btnPad(font: Font): number {
  return Math.round(font.size * 1.25);
}

export function btnBox(
  font: Font,
  labels: string[],
  minW = 0,
  padW = 0,
  minH = 0,
): [number, number] {
  let w = 0;
  for (const label of labels) w = Math.max(w, width(font, label));
  return [Math.max(minW, w + padW), Math.max(minH, font.height + BTN_FRAME + BTN_AIR)];
}

/**
 * How many lines a row of buttons will wrap onto in `w` — the same arithmetic
 * `Buttons.row` uses to lay them out.
 *
 * A caller that reserves one row's height and is handed two paints its last
 * button over whatever is underneath, so anything that puts something *below*
 * a button row has to ask this first.
 */
export function rowsIn(font: Font, labels: string[], w: number, minH = 0, lead = 0): number {
  const gap = Math.round(font.size * 0.5);
  // `lead`: the first line starts this far in — the toolbars' filter box sits
  // at the head of it — and the lines after it start at the left edge.
  let x = lead;
  let rows = 1;
  for (const label of labels) {
    const [bw] = btnBox(font, [label], 0, btnPad(font), minH);
    if (x > 0 && x + bw > w) {
      rows++;
      x = 0;
    }
    x += bw + gap;
  }
  return rows;
}

/**
 * One button. Drawn rounded, as `roundBtn`, in the box the pixel button was
 * measured for, so no screen's layout moves; the options are the same.
 */
export function pixBtn(
  g: Ctx,
  font: Font,
  x: number,
  y: number,
  w: number,
  h: number,
  label: string,
  opts: { lit?: boolean; hover?: boolean; dim?: boolean; quiet?: boolean; strong?: boolean } = {},
): void {
  roundBtn(g, font, x, y + 2, w, h - 4, label, opts);
}

/** A five-pointed star with an ink outline: the "every street CLEAR" mark. */
export function star(g: Ctx, x: number, y: number, r: number, col: RGBA): void {
  g.beginPath();
  for (let i = 0; i <= 9; i++) {
    const a = -Math.PI / 2 + (i * Math.PI) / 5;
    const rr = i % 2 === 0 ? r : r * 0.45;
    const px = x + Math.cos(a) * rr;
    const py = y + Math.sin(a) * rr;
    if (i === 0) g.moveTo(px, py);
    else g.lineTo(px, py);
  }
  g.closePath();
  g.strokeStyle = css(Theme.ink);
  g.lineWidth = 3;
  g.stroke();
  g.fillStyle = css(col);
  g.fill();
  g.lineWidth = 1;
}

const SHADOW: Array<[number, number]> = [
  [2, 2],
  [-2, 2],
  [2, -2],
  [-2, -2],
  [0, 2],
  [2, 0],
];

/** Outlined pixel text, readable on any backdrop. */
export function shadowText(
  g: Ctx,
  font: Font,
  text: string,
  x: number,
  y: number,
  w: number,
  align: "left" | "center" | "right",
  col: RGBA,
): void {
  g.fillStyle = css(Theme.ink);
  for (const [dx, dy] of SHADOW) printf(g, font, text, x + dx, y + dy, w, align);
  g.fillStyle = css(col);
  printf(g, font, text, x, y, w, align);
}

/**
 * The pulsing neon title: five widening ghosts, an ink outline, a white core.
 *
 * The outline is the middle step and it was not there. DESIGN measured the
 * glyph at **8.26:1** against the sky behind it and **2.25:1** where it crosses
 * the pink tenement of `title_bg` — one run of type with its legibility
 * changing along its own length, which is why the game's name read as patchy
 * rather than as dim. A glow is not an outline: it spreads the colour the glyph
 * is already made of, so on a bright patch it adds light to light.
 *
 * Two pixels of `Theme.ink` in the four cardinal directions, which is what a
 * SNES title screen does, and the reason it was chosen over the title plate
 * that was also offered: a plate would cover the painted street that §6 exists
 * to have put there, and the outline only has to win against the worst patch
 * rather than the average one.
 *
 * Order matters. The ghosts first or the outline eats them; the outline before
 * the face or the face is eaten in turn.
 */
export function neonPrint(
  g: Ctx,
  font: Font,
  text: string,
  y: number,
  w: number,
  col: RGBA,
  t: number,
): void {
  const pulse = 0.7 + 0.3 * (0.5 + 0.5 * Math.cos(t * 2.2));
  for (let i = 5; i >= 1; i--) {
    g.fillStyle = css(col, 0.07 * i * pulse);
    printf(g, font, text, -i, y, w, "center");
    printf(g, font, text, i, y, w, "center");
  }
  g.fillStyle = css(Theme.ink);
  for (const [dx, dy] of NEON_OUTLINE) printf(g, font, text, dx, y + dy, w, "center");
  g.fillStyle = `rgba(255,255,255,${pulse})`;
  printf(g, font, text, 0, y, w, "center");
}

/** Four directions, two pixels. Not eight: the diagonals thicken the stroke
 *  into a slab and this type is already heavy. */
const NEON_OUTLINE: Array<[number, number]> = [
  [-2, 0],
  [2, 0],
  [0, -2],
  [0, 2],
];

export function inRect(x: number, y: number, r: Rect | null | undefined): boolean {
  return !!r && x >= r[0] && y >= r[1] && x < r[0] + r[2] && y < r[1] + r[3];
}

/** Clip to a box, run `body`, and put the old clip back. */
export function clipped(g: Ctx, x: number, y: number, w: number, h: number, body: () => void) {
  g.save();
  g.beginPath();
  g.rect(x, y, Math.max(1, w), Math.max(1, h));
  g.clip();
  body();
  g.restore();
}

export { print, printf };

/**
 * The compact, rounded button: the playground's toolbars. The pixel button's
 * bevel takes 20 pixels of height and a font and a quarter of width around
 * every label; across a band of a dozen tools that is a band of air. This is
 * the same label in a pill: a few pixels of rim, rounded corners, the same
 * colour registers as `pixBtn` so a row still says which button is primary.
 */
export const ROUND_FRAME = 10;

export function roundPad(font: Font): number {
  return Math.round(font.size * 0.8);
}

export function roundBox(
  font: Font,
  labels: string[],
  minW = 0,
  padW = 0,
  minH = 0,
): [number, number] {
  let w = 0;
  for (const label of labels) w = Math.max(w, width(font, label));
  return [Math.max(minW, w + padW), Math.max(minH, font.height + ROUND_FRAME)];
}

/** The gap between two rounded buttons on a row. */
export function roundGap(font: Font): number {
  return Math.max(3, Math.round(font.size * 0.3));
}

/** `rowsIn`, for rounded buttons. */
export function roundRowsIn(font: Font, labels: string[], w: number, minH = 0, lead = 0): number {
  const gap = roundGap(font);
  let x = lead;
  let rows = 1;
  for (const label of labels) {
    const [bw] = roundBox(font, [label], 0, roundPad(font), minH);
    if (x > 0 && x + bw > w) {
      rows++;
      x = 0;
    }
    x += bw + gap;
  }
  return rows;
}

/** One rounded button; the options mean what they mean to `pixBtn`. */
export function roundBtn(
  g: Ctx,
  font: Font,
  x: number,
  y: number,
  w: number,
  h: number,
  label: string,
  opts: {
    lit?: boolean;
    hover?: boolean;
    dim?: boolean;
    quiet?: boolean;
    strong?: boolean;
    /** A face of the caller's own — a land's colour — with ink on it. */
    face?: RGBA;
  } = {},
): void {
  const face = opts.face
    ? opts.face
    : opts.dim
      ? Theme.dim
      : opts.strong
        ? opts.hover
          ? Theme.coin
          : Theme.admit
        : opts.lit || opts.hover
          ? Theme.coin
          : opts.quiet
            ? ([0.09, 0.12, 0.3, 1] as RGBA)
            : ([0.16, 0.2, 0.46, 1] as RGBA);
  const r = Math.min(h / 2, Math.max(6, Math.round(font.size * 0.45)));
  g.save();
  roundRect(g, x + 0.5, y + 0.5, w - 1, h - 1, r);
  g.fillStyle = css(face, opts.dim ? 0.55 : 1);
  g.fill();
  g.lineWidth = 1.5;
  g.strokeStyle = css(opts.hover ? Theme.cream : Theme.ink, opts.hover ? 0.9 : 0.75);
  g.stroke();
  // A thin light along the top edge, inside: the pill's only bevel.
  g.clip();
  g.fillStyle = "rgba(255,255,255,0.14)";
  g.fillRect(x, y, w, Math.max(1, Math.round(h * 0.12)));
  g.restore();
  // Ink on the gold faces (lit, hovered, a caller's land colour); cream on
  // every dark one, which is now all the rest.
  const pale = !opts.face && !opts.lit && !opts.hover && !opts.dim;
  g.fillStyle = css(pale ? Theme.cream : Theme.ink, opts.dim ? 0.5 : 1);
  printf(g, font, label, x, inkCentreY(font, label, y, h), w, "center");
}
