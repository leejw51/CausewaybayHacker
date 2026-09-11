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

/**
 * Press Start 2P for the chrome, VT323 for body text — and behind both, a CJK
 * face, because neither of the two has a single Korean, Japanese or Chinese
 * glyph in it. Their `cmap` tables were read rather than assumed: Czech and
 * the rest of Latin are covered by both, in upper and lower case, diacritics
 * included; Hangul, kana and Han are covered by neither.
 *
 * There are two layers of fallback and the order is the whole design:
 *
 *   1. **Noto Sans CJK**, when it has been loaded for the active language
 *      (`setCjkFamily`, driven by `i18n/`). It is the subset the sibling LÖVE
 *      client ships, so both clients draw the same shapes, and it is fetched
 *      only when a language that needs it is chosen — never for English or
 *      Czech, which the two pixel faces already cover.
 *
 *      It is a vector face in a pixel-art game, and `image-rendering:
 *      pixelated` does not apply to canvas text, so there is no way to make it
 *      *be* a pixel font. The choice made here is to let it be smooth and to
 *      make it **bigger** instead (`CJK_FLOOR` below): a legible anti-aliased
 *      Hangul beside crisp pixel Latin reads as two typefaces, which is what
 *      it is, while a mangled 7-pixel Hangul reads as a broken game.
 *   2. **The system CJK stack**, which is what was here before and is still
 *      the floor. It works offline, costs nothing, and renders a smooth,
 *      anti-aliased, entirely wrong-looking Korean next to crisp pixel Latin.
 *      That is a far better failure than a row of tofu boxes, which is what a
 *      machine with no CJK system font shows instead.
 */
const CJK =
  '"Noto Sans CJK KR","Noto Sans CJK SC","Noto Sans KR","Noto Sans SC","Hiragino Sans",' +
  '"Yu Gothic","Microsoft YaHei","Malgun Gothic",sans-serif';

/** The pixel CJK family for the active language, or "" for none. */
let cjk = "";

/**
 * Name the CJK pixel family that is now resident, or clear it.
 *
 * Called by `i18n/` after the font has actually finished loading, never
 * before: a family named in a stack it cannot supply is a frame measured
 * against the fallback and then re-laid-out when it lands, which is the jump
 * `boot.ts` already goes out of its way to avoid for the two Latin faces.
 *
 * It drops every cached measurement, because every one of them was taken
 * against a different stack.
 */
export function setCjkFamily(family: string): void {
  if (family === cjk) return;
  cjk = family;
  remeasure();
}

export function cjkFamily(): string {
  return cjk;
}

const back = () => (cjk ? `"${cjk}",${CJK}` : CJK);
/**
 * Each pixel face backs the other, and that is not tidiness.
 *
 * `\u2605`, `\u2190` and `\u2192` are in Press Start 2P and **not** in VT323 —
 * they are the stars on the lands panel and the arrows that start every footer
 * hint. The moment the small chrome face moved from one to the other, every
 * one of them would have dropped through to whatever the system had, or to
 * nothing. Naming both faces in both stacks costs one word each and keeps a
 * missing glyph inside the game's own two typefaces before it reaches the
 * CJK face or the machine's.
 */
const PIXEL = () => `"PressStart2P","VT323",ui-monospace,monospace,${back()}`;
const BODY = () => `"VT323","PressStart2P",ui-monospace,monospace,${back()}`;

/** The two stacks, for the font-coverage test. */
export function fontStacks(): { pixel: string; body: string } {
  return { pixel: PIXEL(), body: BODY() };
}

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

/**
 * The smallest type a CJK language is allowed to be drawn at, in virtual px.
 *
 * A Hangul syllable packs three or four strokes into the em box that Latin
 * spends on one letterform, so the same nominal size is not the same
 * legibility: at 8 virtual px a capital H is small and `과` has lost the
 * strokes that tell it from `관`. The floor is applied here rather than at the
 * hundred-odd call sites, and it is lifted only while a CJK language is
 * active — Czech and English would just look bulky.
 *
 * 24 is a multiple of eight, so the Latin words inside a Korean sentence still
 * land on Press Start 2P's grid. It costs less width than it looks: CJK says
 * in two or three glyphs what English says in eight characters, so a 24px
 * Korean button label is still narrower than its 16px English original.
 */
const CJK_FLOOR = 24;

/** Virtual px of the floor, or 0 when the active language is a Latin one. */
let floorPx = 0;

/**
 * Raise (or drop) the CJK legibility floor. Driven by `i18n/`, alongside
 * `setCjkFamily` — a language that needs the CJK face is exactly a language
 * that needs the floor.
 */
export function setCjkFloor(on: boolean): void {
  const px = on ? CJK_FLOOR : 0;
  if (px === floorPx) return;
  floorPx = px;
  remeasure();
}

export function cjkFloor(): number {
  return floorPx;
}

let scaleKey = "";
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
  // The active CJK family is part of the key. Without it, switching language
  // hands back the record built for the previous one and every Korean string
  // on screen is measured — and drawn — in a stack that cannot render it.
  const key = `${Math.round(s * 100)}\n${cjk}\n${floorPx}`;
  if (key === scaleKey && fonts) return fonts;
  scaleKey = key;
  widths = new Map();
  const pixel = PIXEL();
  const body = BODY();
  /**
   * No smaller than the floor, whatever the role asked for — except for the
   * two code faces. What is in the editor and in a sample well is Rust or Go,
   * in Latin, in every language; raising it because the *interface* is Korean
   * would push the player's own work around for no reading benefit. The
   * editor has its own size control (A- / A+ on the quest screen) and that is
   * the right place for that preference.
   */
  const at = (n: number) => Math.max(n, floorPx * s);
  fonts = {
    title: make(at(snap8(40 * s)), pixel),
    subtitle: make(at(40 * s), body),
    ui: make(at(snap8(20 * s)), pixel),
    small: make(at(30 * s), body),
    code: make(28 * s, body),
    codeSm: make(22 * s, body),
    bubble: make(at(30 * s), body),
    station: make(at(snap8(20 * s)), pixel),
    // The small chrome face — panel titles, the footer key bar, captions, the
    // quest toolbar — is VT323 at 20 rather than Press Start 2P at 8, and the
    // swap is free: the two have the *same advance width* (8 virtual px), so
    // nothing reflows, while the cap height goes 7 -> 11.2 and a Hangul
    // syllable goes 7.2 -> 18.1. Eight-pixel Press Start 2P was the least
    // readable thing in the game and the labels of the controls were written
    // in it.
    stationSm: make(at(20 * s), body),
    // 20 rather than 16: a control whose label you cannot read at arm's
    // length is not a control. Press Start 2P is on an eight-pixel grid, so
    // this lands on 16 or 24 depending on the scale rather than anywhere in
    // between, and the rows that hold these buttons wrap by measurement
    // (`Buttons.row`, `rowsIn`) rather than by a fixed count.
    button: make(at(snap8(20 * s)), pixel),
    stamp: make(at(snap8(24 * s)), pixel),
    help: make(at(32 * s), body),
  };
  return fonts;
}

/** Forget every measurement. Called once the real fonts finish downloading:
 *  anything measured against the fallback is the wrong width. */
export function remeasure(): void {
  scaleKey = "";
  widths = new Map();
  sized.clear();
}

/**
 * One body-face font at an arbitrary size, cached.
 *
 * For the one job that genuinely needs a size nobody picked in advance: the
 * footer key bar, which must hold every hint on **one line** in six languages
 * and at any window width. Shrinking it to fit is better than wrapping it (the
 * bar has a fixed height that half the screens reserve room against) and much
 * better than dropping hints off the end, which is how a player stops learning
 * the keyboard.
 */
const sized = new Map<string, Font>();
export function bodyFontAt(px: number): Font {
  const n = Math.max(8, Math.round(px));
  const key = `${n}\n${cjk}`;
  let f = sized.get(key);
  if (!f) {
    f = make(n, BODY());
    if (sized.size > 64) sized.clear();
    sized.set(key, f);
  }
  return f;
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

/**
 * May a line start with this character, with no space in front of it?
 *
 * Chinese and Japanese are written without spaces, so every ideograph is a
 * break opportunity and a line can be broken between any two of them.
 *
 * **Korean is not.** It is written with spaces between words, and breaking it
 * per syllable the way the ideographs are broken produces `\ubcf4\ub2c8 / \ub2e4.`
 * — a word split down the middle for no reason, which is what the Korean login
 * note did. Hangul is therefore *not* listed here: it wraps on spaces like
 * Latin, and `wrap()` falls back to breaking inside a word only when one word
 * is wider than the whole line.
 */
function isBreakable(ch: string): boolean {
  const c = ch.codePointAt(0) ?? 0;
  return (
    (c >= 0x2e80 && c <= 0x9fff) || // radicals through the unified ideographs
    (c >= 0xf900 && c <= 0xfaff) ||
    (c >= 0xff00 && c <= 0xff60) // fullwidth forms
  );
}

/**
 * Characters that may not begin a line.
 *
 * Kinsoku sh\u014dri, the one rule of CJK line breaking that a reader notices
 * immediately: because every ideograph is its own break opportunity, a line can
 * otherwise end on a word and the next one start with the full stop that closed
 * it. A Korean paragraph on the coaching panel did exactly that — a line
 * beginning `. \uc2e4\ud328\ud55c` — which reads as a typesetting fault rather
 * than as a language.
 */
const NO_START = new Set([
  ...".,:;?!)]}%\u2019\u201d",
  ..."\u3002\u3001\uff0c\uff0e\u30fb\uff1a\uff1b\uff1f\uff01",
  ..."\u300d\u300f\uff09\uff3d\uff5d\u3009\u300b\u00bb\u2026",
]);

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
  // Closing punctuation goes back onto the piece it closes, so it can never be
  // pushed onto the next line on its own.
  const joined: string[] = [];
  for (const tok of out) {
    if (joined.length > 0 && tok.length > 0 && NO_START.has(tok[0])) joined[joined.length - 1] += tok;
    else joined.push(tok);
  }
  return joined;
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
      // One word wider than the line it is on — a Korean compound in a narrow
      // panel, or a URL. Space-breaking cannot help, so this is where it is
      // allowed to break inside the word rather than run off the edge.
      while (width(f, line.trimEnd()) > limit && [...line.trimEnd()].length > 1) {
        const chars = [...line];
        let cut = chars.length - 1;
        while (cut > 1 && width(f, chars.slice(0, cut).join("").trimEnd()) > limit) cut--;
        lines.push(chars.slice(0, cut).join("").trimEnd());
        line = chars.slice(cut).join("");
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
