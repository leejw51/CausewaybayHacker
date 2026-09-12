/**
 * Six languages, one source, and one font problem.
 *
 * ## What is translated, and what is deliberately not
 *
 * **The interface.** Every label, every panel title, every message this client
 * writes itself. English is the source and the other five are translated from
 * it; a key missing from a locale falls back to English rather than to a blank,
 * and `tests/i18n.test.ts` fails if one ever is.
 *
 * **The quests, when a translation pack exists — and the server says which.**
 * Quest prose lives in `content/` and is translated there, not here: a pack per
 * language under `content/i18n/<locale>/` (SPEC §12.1), written by somebody who
 * can check that a Rust ownership brief still teaches ownership afterwards. The
 * client's only part is to send `locale()` with `quest.get`, `world.map` and
 * `quest.hint`; the server substitutes what it has and answers `text_locale`
 * on the quest and on every map node. When that is not the language on screen
 * — no pack yet, or a quest the pack has not reached — the quest screen says
 * the brief is in English, in as many words, rather than letting it read as a
 * half-finished translation. Code is never translated in any language.
 *
 * **Not the server's `message`.** PROTOCOL §3.3 is explicit that it is for a
 * developer and not for the player; the client already renders its own text
 * from the `code`, and that text is translated here.
 *
 * ## The font problem, which is the hard half
 *
 * Neither Press Start 2P nor VT323 has a single Korean, Japanese or Chinese
 * glyph — read out of their `cmap` tables, not assumed. Czech is fine in both,
 * upper and lower case, diacritics included. So four of the six languages need
 * a face that neither of the two provides, and what happens without one depends
 * on the machine: on a laptop with system CJK fonts the browser quietly
 * substitutes a smooth, anti-aliased Hiragino or Malgun beside the crisp pixel
 * Latin, which is legible and looks wrong; on a machine without them it is a
 * row of tofu boxes.
 *
 * The answer is **Fusion Pixel 12px** (OFL-1.1, TakWolf, built on Ark Pixel,
 * Cubic 11 and Galmuri — every licence is in `public/fonts/fusion-pixel/`). It
 * is a bitmap pixel face covering Hangul, kana, and both simplified and
 * traditional Han in one file, so it keeps the 16-bit look instead of breaking
 * it. Four regional builds are shipped, because the same Han character is drawn
 * differently in Japanese and in Chinese and a Japanese player reading Chinese
 * glyph forms notices. Each is ~900 KB as woff2 and **only the one in use is
 * ever fetched**: English and Czech download nothing at all, and switching to
 * Korean costs one 903 KB file, once, cached thereafter.
 *
 * The load is awaited before the family is named to `engine/text.ts`, for the
 * reason `boot.ts` already documents for the Latin faces: a family named in a
 * stack that cannot yet supply it means every panel is measured against the
 * fallback and then jumps when the real font lands.
 */
import { remeasure, setCjkFamily, setCjkFloor } from "../engine/text";
import { readEnumPref, writePref } from "../ui/prefs";
import { en } from "./en";
import { ko } from "./ko";
import { yue } from "./yue";
import { zh } from "./zh";
import { ja } from "./ja";
import { cs } from "./cs";

export type Locale = "en" | "ko" | "yue" | "zh" | "ja" | "cs";
export type Strings = typeof en;
/** Every other locale is checked against the English catalogue, key for key. */
export type Catalogue = Record<keyof Strings, string>;

const LOCALE_KEY = "locale";

export interface LocaleInfo {
  id: Locale;
  /** The language's name **in that language**, which is the only useful label. */
  label: string;
  /** And in English, for a report or a log. */
  english: string;
  /**
   * The CJK font this language needs, or null when the two Latin faces already
   * cover it. `cs` is null and that is not an oversight — Press Start 2P and
   * VT323 both carry the full Czech alphabet, and the CJK face does *not*:
   * `\u010d` and `\u0159` are absent from it, `\u011b` is present, which is
   * exactly the shape of bug that would leave Czech half-rendered while all
   * four CJK languages looked perfect. Latin and Czech come from the pixel
   * faces, CJK from Noto, and the stack in `engine/text.ts` puts them in that
   * order.
   */
  font: { family: string; file: string } | null;
}

/**
 * One face for all four CJK languages.
 *
 * `NotoSansCJK-Regular.otf` from the sibling LÖVE client
 * (`CausewaybayGolang/love2d/assets/fonts/`), already subsetted there to
 * Hangul, kana, unified ideographs and fullwidth forms — 33,243 codepoints,
 * read out of its `cmap` rather than taken on trust. It ships here as woff2
 * because an 11.2 MB OTF over the wire is not a thing to do to a player; the
 * glyphs are identical, the container is not. 6.4 MB, fetched once, and only
 * when a language that needs it is chosen.
 *
 * It is the **SC** cut, so the Han forms are the mainland ones in Japanese and
 * in traditional Cantonese too. That is a real cost and it is the sibling's
 * choice carried over deliberately: one reviewed 6.4 MB file that both clients
 * share beats four regional files that only this one has.
 */
const NOTO = { family: "NotoSansCJK", file: "/fonts/noto-sans-cjk/NotoSansCJK-Regular.woff2" };

export const LOCALES: readonly LocaleInfo[] = [
  { id: "en", label: "ENGLISH", english: "English", font: null },
  {
    id: "ko",
    label: "한국어",
    english: "Korean",
    font: NOTO,
  },
  {
    id: "yue",
    label: "廣東話",
    english: "Cantonese",
    font: NOTO,
  },
  {
    id: "zh",
    label: "简体中文",
    english: "Chinese (Simplified)",
    font: NOTO,
  },
  {
    id: "ja",
    label: "日本語",
    english: "Japanese",
    font: NOTO,
  },
  { id: "cs", label: "ČEŠTINA", english: "Czech", font: null },
];

const IDS = LOCALES.map((l) => l.id);

const TABLES: Record<Locale, Partial<Catalogue>> = { en, ko, yue, zh, ja, cs };

let active: Locale = "en";
let table: Partial<Catalogue> = en;
/**
 * The in-flight font load for the current language.
 *
 * `setLocale` swaps the table *synchronously* — everything before its first
 * `await` runs on the call — and only the font is asynchronous. So the boot
 * screen can put the right words up immediately and wait for the face
 * separately, which is the same split `boot.ts` already makes for the two
 * Latin faces and for the same reason: a screen laid out against a fallback
 * and then re-laid-out when the real font arrives visibly jumps.
 */
let pending: Promise<void> = Promise.resolve();

/** Resolves when the active language's font is resident (or has failed). */
export function localeReady(): Promise<void> {
  return pending;
}

export function locale(): Locale {
  return active;
}

export function localeInfo(id: Locale = active): LocaleInfo {
  return LOCALES.find((l) => l.id === id) ?? LOCALES[0];
}

/**
 * Which plural form a count takes.
 *
 * Three of the six languages have no grammatical plural at all, English has
 * two forms and Czech has three (1 / 2–4 / 5 and up). A key that needs it is
 * written as `foo.one`, `foo.few` and `foo.other`, and the ones that do not
 * are written plainly — most are, because most of the counts on screen are in
 * a phrase that does not inflect.
 *
 * It is not a general CLDR implementation and does not pretend to be: Czech's
 * genitive-plural rule for decimals and its "many" category for fractions are
 * not reachable from anything this game counts, which are all small integers.
 */
function plural(n: number): "one" | "few" | "other" {
  switch (active) {
    case "cs":
      if (n === 1) return "one";
      if (n >= 2 && n <= 4) return "few";
      return "other";
    case "en":
      return n === 1 ? "one" : "other";
    default:
      // Korean, Cantonese, Chinese and Japanese do not inflect for number.
      return "other";
  }
}

/**
 * One string, by key, with `{name}` placeholders filled in.
 *
 * A key that is missing from the active locale falls back to English rather
 * than to the key itself or to nothing: a half-translated screen in two
 * languages is readable and a half-translated screen with holes in it is not.
 * The test suite is what keeps that path from ever being taken in a shipped
 * build.
 */
export function t(key: keyof Strings, vars?: Record<string, string | number>): string {
  const raw = table[key] ?? en[key] ?? String(key);
  if (!vars) return raw;
  return raw.replace(/\{(\w+)\}/g, (m, name: string) => (name in vars ? String(vars[name]) : m));
}

/** `t`, choosing between `<key>.one`, `<key>.few` and `<key>.other` on `n`. */
export function tn(key: string, n: number, vars?: Record<string, string | number>): string {
  const want = `${key}.${plural(n)}` as keyof Strings;
  const fall = `${key}.other` as keyof Strings;
  const raw = table[want] ?? en[want] ?? table[fall] ?? en[fall] ?? String(key);
  return raw.replace(/\{(\w+)\}/g, (m, name: string) => {
    if (name === "n") return String(n);
    return vars && name in vars ? String(vars[name]) : m;
  });
}

/**
 * Load a language's pixel font, if it has one.
 *
 * Resolves either way — a font that will not download is a cosmetic failure and
 * must not stop somebody changing language. `false` back means "carry on with
 * the system stack", which is exactly what `engine/text.ts` does when no family
 * is named.
 */
/**
 * Which families this module has actually added, by name.
 *
 * **Not** `document.fonts.check()`, and that distinction cost a round of
 * screenshots. `FontFaceSet.check()` answers "can this text be rendered without
 * waiting for a font that is still loading" — and a family the set has never
 * heard of has nothing to wait for, so it answers **true**. Used as a
 * did-I-already-load-this guard it returns true on the very first call, the
 * fetch is skipped, the family is named to `engine/text.ts`, the browser cannot
 * supply it, and every CJK glyph quietly comes out of the system stack. Four
 * languages looked translated and none of them was in the pixel face.
 *
 * A set we write ourselves cannot lie about that.
 */
const loaded = new Set<string>();

async function loadFont(info: LocaleInfo): Promise<boolean> {
  if (!info.font) return false;
  const { family, file } = info.font;
  if (loaded.has(family)) return true;
  try {
    if (typeof FontFace === "undefined" || !document.fonts) return false;
    const face = new FontFace(family, `url(${file})`, { display: "swap" });
    await face.load();
    document.fonts.add(face);
    loaded.add(family);
    return true;
  } catch {
    // A face that will not download is a cosmetic failure: the system CJK
    // stack behind it still renders the words. It must not stop somebody
    // changing language.
    return false;
  }
}

/**
 * Change language, everywhere, now.
 *
 * The order is the whole of it: swap the table, fetch the face, *wait* for it,
 * and only then name it to the text engine and drop every cached measurement.
 * Naming it first would measure a screen's worth of panels against a stack that
 * cannot draw the glyphs and lay the whole thing out to the wrong width.
 */
export function setLocale(id: Locale, remember = true): Promise<void> {
  const info = LOCALES.find((l) => l.id === id) ?? LOCALES[0];
  active = info.id;
  table = TABLES[info.id];
  if (remember) writePref(LOCALE_KEY, info.id);
  // The legibility floor moves with the *script*, not with the download: it is
  // needed just as much while the system CJK stack is standing in, so it is
  // raised now rather than in the callback below.
  setCjkFloor(info.font !== null);
  // Every string is already the new language from here; only the face is
  // outstanding. `remeasure` is called twice on purpose — once now, because
  // the words changed and every cached width is for the old ones, and once
  // when the font lands, because the same words are a different width in it.
  remeasure();
  pending = loadFont(info).then((ok) => {
    if (locale() !== info.id) return;
    setCjkFamily(ok && info.font ? info.font.family : "");
    remeasure();
  });
  return pending;
}

/** The next language round the list. What F7 and the LANG button do. */
export function nextLocale(): Locale {
  const i = IDS.indexOf(active);
  return IDS[(i + 1) % IDS.length];
}

/**
 * The language to start in.
 *
 * A remembered choice wins. Failing that the browser is asked, because a player
 * whose machine is already in Japanese should not have to find a menu to say so
 * — and `navigator.language` is the only honest guess available. Anything
 * unrecognised is English.
 */
export function preferredLocale(): Locale {
  const saved = readEnumPref<Locale>(LOCALE_KEY, IDS, "" as Locale);
  if (saved) return saved;
  try {
    for (const tag of navigator.languages ?? [navigator.language]) {
      const lower = (tag ?? "").toLowerCase();
      // `yue` before `zh`, and `zh-HK` / `zh-Hant-HK` with it: a Hong Kong
      // browser asking for traditional Chinese is the Cantonese audience this
      // game is set among, and handing it simplified would be the wrong answer
      // in the one city it is about.
      if (lower.startsWith("yue") || lower.startsWith("zh-hk") || lower.startsWith("zh-hant-hk")) {
        return "yue";
      }
      if (lower.startsWith("ko")) return "ko";
      if (lower.startsWith("ja")) return "ja";
      if (lower.startsWith("zh")) return "zh";
      if (lower.startsWith("cs")) return "cs";
      if (lower.startsWith("en")) return "en";
    }
  } catch {
    /* an embedder with no navigator gets English */
  }
  return "en";
}

/** For the tests: every catalogue, so completeness can be asserted. */
export const TABLES_FOR_TEST = TABLES;
export const EN_FOR_TEST = en;
