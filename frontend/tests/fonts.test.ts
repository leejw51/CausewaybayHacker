/**
 * The fonts cover every language.
 *
 * Borrowed, name and all, from the sibling LÖVE client — it is the check that
 * stops a translation from turning into tofu months later when somebody adds a
 * string with a character nothing on the wire can draw. The reading of the
 * `cmap` tables happens offline in `tools/fontcover.py`, because a woff2 is
 * brotli-compressed and the test environment has no decompressor; this checks
 * the six catalogues against what that found.
 *
 * The asymmetry is the point. Korean, Japanese, Chinese and Cantonese are
 * allowed to need Noto. English and Czech are **not** — they are drawn with no
 * CJK face present, and the Noto subset does not even carry `č` or `ř`, so a
 * Czech string that strayed outside the pixel faces would be half-drawn on
 * screen and perfect in every test that only counted keys.
 */
import { describe, expect, it } from "vitest";
import coverage from "./font-coverage.json";
import { en } from "../src/i18n/en";
import { ko } from "../src/i18n/ko";
import { yue } from "../src/i18n/yue";
import { zh } from "../src/i18n/zh";
import { ja } from "../src/i18n/ja";
import { cs } from "../src/i18n/cs";
import { LOCALES } from "../src/i18n";
import { fontStacks } from "../src/engine/text";

/** "20-7E,A0" → a predicate. */
function set(ranges: string[]): (cp: number) => boolean {
  const pairs = ranges.map((r) => {
    const [a, b] = r.split("-");
    return [parseInt(a, 16), parseInt(b ?? a, 16)] as const;
  });
  return (cp) => pairs.some(([lo, hi]) => cp >= lo && cp <= hi);
}

const latin = set(coverage.latin);
const latinAny = set(coverage.latinAny);
const cjk = set(coverage.cjk);

/** Every distinct codepoint in a catalogue, with the ASCII we know is fine dropped. */
function chars(table: Record<string, string>): number[] {
  const out = new Set<number>();
  for (const v of Object.values(table)) {
    for (const ch of v) {
      const cp = ch.codePointAt(0)!;
      if (cp >= 0x20 && cp <= 0x7e) continue;
      out.add(cp);
    }
  }
  return [...out].sort((a, b) => a - b);
}

const show = (cp: number) => `${String.fromCodePoint(cp)} U+${cp.toString(16).toUpperCase()}`;

describe("the fonts cover every language", () => {
  it("English and Czech need no CJK face at all", () => {
    // These two are drawn by the pixel faces alone — `LOCALES` says so by
    // giving them no font, and this is the other half of that promise.
    for (const [name, table] of [
      ["en", en],
      ["cs", cs],
    ] as const) {
      const missing = chars(table).filter((cp) => !latinAny(cp));
      expect(missing.map(show), `${name} has characters no pixel face carries`).toEqual([]);
    }
    expect(LOCALES.filter((l) => l.font === null).map((l) => l.id)).toEqual(["en", "cs"]);
  });

  it("each pixel face is in the other's stack, so covered-by-one is enough", () => {
    // Covered-by-one is only good enough because of this. `★ ← →` live in
    // Press Start 2P and not in VT323, so the first time a label moved from
    // one face to the other every star and every footer arrow would have
    // dropped through to the system — or to nothing. Both stacks name both
    // faces, and this is the check that says they still do.
    const { pixel, body } = fontStacks();
    for (const stack of [pixel, body]) {
      expect(stack).toContain('"PressStart2P"');
      expect(stack).toContain('"VT323"');
    }
    // And the glyphs that forced the point are still where we think they are.
    const star = "★".codePointAt(0)!;
    expect(latinAny(star)).toBe(true);
    expect(latin(star)).toBe(false);
  });

  it("the CJK languages are covered by the pixel faces plus Noto", () => {
    for (const [name, table] of [
      ["ko", ko],
      ["yue", yue],
      ["zh", zh],
      ["ja", ja],
    ] as const) {
      const missing = chars(table).filter((cp) => !latinAny(cp) && !cjk(cp));
      expect(missing.map(show), `${name} has characters nothing shipped can draw`).toEqual([]);
    }
  });

  it("the manifest is the fonts that are actually shipped", () => {
    // A stale manifest would pass every check above while describing a font
    // that is no longer in `public/`. The sizes are the cheap tell.
    expect(Object.keys(coverage.fonts).sort()).toEqual([
      "PressStart2P-Regular.ttf",
      "VT323-Regular.ttf",
      "noto-sans-cjk/NotoSansCJK-Regular.woff2",
    ]);
    for (const bytes of Object.values(coverage.fonts)) expect(bytes).toBeGreaterThan(0);
  });
});
