// Ported from CausewaybayGolang/typescript/src/engine/text.ts (which in turn
// carries it over from that project's love2d Lua). Kept close to the original
// so a fix made there can still be read across; Causewaybay Hacker changes are
// marked where they occur.
/**
 * Type, measured and wrapped the way LÖVE does it.
 *
 * `love2d/src/assets.lua` builds twelve fonts across two families and rebuilds
 * them whenever the virtual canvas changes size. The same twelve are here at
 * the same sizes, so a panel measured against `font:getHeight()` in the Lua
 * comes out the same height in the browser.
 *
 * Two things the desktop build gets for free have to be done by hand:
 *
 *   - **Measuring is expensive.** `measureText` is a layout call and the game
 *     asks for the same handful of labels sixty times a second. Widths are
 *     cached on (font, string) and the cache is dropped when the fonts are
 *     rebuilt at a new scale.
 *   - **CJK does not wrap on spaces.** LÖVE breaks anywhere inside a run of
 *     ideographs; a canvas does not wrap at all, so the line breaker below
 *     treats every CJK character as a word of its own. Without it a Cantonese
 *     sentence is one very wide line.
 */

/** Press Start 2P for the chrome, VT323 for body text, the system CJK behind both. */
const CJK =
  '"Noto Sans CJK KR","Noto Sans CJK SC","Noto Sans KR","Noto Sans SC","Hiragino Sans",' +
  '"Yu Gothic","Microsoft YaHei","Malgun Gothic",sans-serif';
const PIXEL = `"PressStart2P",ui-monospace,monospace,${CJK}`;
const BODY = `"VT323",ui-monospace,monospace,${CJK}`;

export type FontName =
  | "title"
  | "subtitle"
  | "ui"
  | "small"
  | "code"
  | "codeSm"
  | "bubble"
  | "station"
  | "stationSm"
  | "button"
  | "stamp"
  | "help";

export interface Font {
  css: string;
  size: number;
  height: number;
}

/** Press Start 2P only looks right on multiples of eight. */
function snap8(n: number): number {
  return Math.max(8, Math.round(n / 8) * 8);
}

let scaleKey = -1;
let fonts: Record<FontName, Font> | null = null;
let widths = new Map<string, number>();
let measurer: CanvasRenderingContext2D | null = null;

function ctx2d(): CanvasRenderingContext2D {
  if (!measurer) {
    const c = document.createElement("canvas");
    c.width = 8;
    c.height = 8;
    const g = c.getContext("2d");
    if (!g) throw new Error("no 2d context for measuring text");
    measurer = g;
  }
  return measurer;
}

function make(size: number, family: string): Font {
  const px = Math.max(8, Math.round(size));
  const css = `${px}px ${family}`;
  const g = ctx2d();
  g.font = css;
  const m = g.measureText("Hg");
  // fontBoundingBox is the whole line box, which is what getHeight() returns.
  // Where an engine leaves it undefined, the em size plus a fifth is close for
  // both families and only affects how tall a panel comes out.
  const asc = m.fontBoundingBoxAscent ?? px;
  const desc = m.fontBoundingBoxDescent ?? px * 0.2;
  return { css, size: px, height: Math.max(px, Math.round(asc + desc)) };
}

/**
 * Build the twelve fonts for a UI scale. Cheap to call every frame: it does
 * nothing unless the scale actually moved.
 */
export function ensureFonts(scale: number): Record<FontName, Font> {
  const s = Math.max(1, scale);
  const key = Math.round(s * 100);
  if (key === scaleKey && fonts) return fonts;
  scaleKey = key;
  widths = new Map();
  fonts = {
    title: make(snap8(40 * s), PIXEL),
    subtitle: make(40 * s, BODY),
    ui: make(snap8(16 * s), PIXEL),
    small: make(30 * s, BODY),
    code: make(28 * s, BODY),
    codeSm: make(22 * s, BODY),
    bubble: make(30 * s, BODY),
    station: make(snap8(16 * s), PIXEL),
    stationSm: make(snap8(8 * s), PIXEL),
    button: make(snap8(16 * s), PIXEL),
    stamp: make(snap8(24 * s), PIXEL),
    help: make(32 * s, BODY),
  };
  return fonts;
}

/** Forget every measurement. Called once the real fonts finish downloading:
 *  anything measured against the fallback is the wrong width. */
export function remeasure(): void {
  scaleKey = -1;
  widths = new Map();
}

export function font(name: FontName): Font {
  return (fonts ?? ensureFonts(1))[name];
}

export function width(f: Font, text: string): number {
  // A separator that cannot appear in either half: a font string is full of
  // spaces and commas, so "16px VT323, x" and "16px VT323" + ", x" would
  // otherwise share a cache entry.
  const key = `${f.css}\n${text}`;
  const hit = widths.get(key);
  if (hit !== undefined) return hit;
  const g = ctx2d();
  g.font = f.css;
  const w = g.measureText(text).width;
  // Labels are a fixed set, but typed answers and code lines are not, so the
  // cache is bounded. Twenty thousand entries is well past any one screen.
  if (widths.size > 20000) widths.clear();
  widths.set(key, w);
  return w;
}

/** May a line start with this character, with no space in front of it? */
function isBreakable(ch: string): boolean {
  const c = ch.codePointAt(0) ?? 0;
  return (
    (c >= 0x1100 && c <= 0x11ff) || // Hangul jamo
    (c >= 0x2e80 && c <= 0x9fff) || // radicals through the unified ideographs
    (c >= 0xa960 && c <= 0xa97f) ||
    (c >= 0xac00 && c <= 0xd7ff) || // Hangul syllables
    (c >= 0xf900 && c <= 0xfaff) ||
    (c >= 0xff00 && c <= 0xff60) // fullwidth forms
  );
}

/** Split into the smallest pieces a line may be broken between. */
function tokens(text: string): string[] {
  const out: string[] = [];
  let run = "";
  for (const ch of text) {
    if (isBreakable(ch)) {
      if (run) out.push(run);
      run = "";
      out.push(ch);
    } else if (ch === " ") {
      out.push(run + ch);
      run = "";
    } else {
      run += ch;
    }
  }
  if (run) out.push(run);
  return out;
}

/** `font:getWrap(text, limit)`: the lines the text breaks into. */
export function wrap(f: Font, text: string, limit: number): string[] {
  const lines: string[] = [];
  for (const para of String(text ?? "").split("\n")) {
    if (para === "") {
      lines.push("");
      continue;
    }
    let line = "";
    for (const tok of tokens(para)) {
      const next = line + tok;
      if (line !== "" && width(f, next.trimEnd()) > limit) {
        lines.push(line.trimEnd());
        line = tok.trimStart() === "" ? "" : tok;
      } else {
        line = next;
      }
    }
    lines.push(line.trimEnd());
  }
  return lines;
}

export type Align = "left" | "center" | "right";

/** `love.graphics.print`: `y` is the top of the line, not a baseline. */
export function print(
  g: CanvasRenderingContext2D,
  f: Font,
  text: string,
  x: number,
  y: number,
): void {
  g.font = f.css;
  g.textAlign = "left";
  g.textBaseline = "top";
  g.fillText(text, x, y);
}

/** `love.graphics.printf`: wrapped to `limit` and aligned inside it. */
export function printf(
  g: CanvasRenderingContext2D,
  f: Font,
  text: string,
  x: number,
  y: number,
  limit: number,
  align: Align = "left",
): number {
  g.font = f.css;
  g.textBaseline = "top";
  g.textAlign = "left";
  const lines = wrap(f, text, limit);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    let lx = x;
    if (align === "center") lx = x + (limit - width(f, line)) * 0.5;
    else if (align === "right") lx = x + limit - width(f, line);
    g.fillText(line, lx, y + i * f.height);
  }
  return lines.length;
}
