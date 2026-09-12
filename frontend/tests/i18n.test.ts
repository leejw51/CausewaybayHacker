/**
 * The six catalogues, checked against each other.
 *
 * Translation rots in exactly one way: a key is added to English, the screen
 * works, nobody notices that five languages have quietly fallen back to it, and
 * six months later a Korean player is reading a paragraph of English in the
 * middle of a Korean panel. The fallback in `t()` is there so a gap is readable
 * rather than blank — it is not permission to have gaps, and this is what says
 * so out loud.
 *
 * It also checks the things a human translator gets wrong that a compiler
 * cannot see: a `{name}` placeholder dropped or misspelled (the value then
 * prints a literal brace at the player), and a plural family that is short a
 * form in the one language that needs three.
 */
import { describe, expect, it } from "vitest";
import { en } from "../src/i18n/en";
import { ko } from "../src/i18n/ko";
import { yue } from "../src/i18n/yue";
import { zh } from "../src/i18n/zh";
import { ja } from "../src/i18n/ja";
import { cs } from "../src/i18n/cs";
import { LOCALES, locale, onLocale, setLocale, t, tn } from "../src/i18n";

const OTHERS = { ko, yue, zh, ja, cs } as const;
type Key = keyof typeof en;

const keys = Object.keys(en) as Key[];

/** `{name}` placeholders in a string, as a sorted, de-duplicated list. */
function slots(s: string): string[] {
  return [...new Set([...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]))].sort();
}

describe("the catalogues", () => {
  it("English has no duplicate or empty values by accident", () => {
    for (const k of keys) expect(en[k], `${k} is empty`).not.toBe("");
  });

  for (const [name, table] of Object.entries(OTHERS)) {
    it(`${name} has every key English has`, () => {
      const missing = keys.filter((k) => !(k in table));
      expect(missing, `${name} is missing ${missing.length} keys`).toEqual([]);
    });

    it(`${name} has no key English does not`, () => {
      // A stale key is a translation of a string that is no longer on screen,
      // and it hides the fact that the screen changed under it.
      const extra = Object.keys(table).filter((k) => !(k in en));
      expect(extra, `${name} has keys that are not in English`).toEqual([]);
    });

    it(`${name} keeps every placeholder`, () => {
      const wrong: string[] = [];
      for (const k of keys) {
        const v = (table as Record<string, string>)[k];
        if (v === undefined) continue;
        const a = slots(en[k]);
        const b = slots(v);
        if (a.join(",") !== b.join(",")) wrong.push(`${k}: {${a}} vs {${b}}`);
      }
      expect(wrong).toEqual([]);
    });

    it(`${name} has nothing empty`, () => {
      const blank = Object.entries(table)
        .filter(([, v]) => typeof v !== "string" || v.trim() === "")
        .map(([k]) => k);
      expect(blank).toEqual([]);
    });
  }

  it("every plural family is complete in every language", () => {
    // A `.one` implies a `.few` and an `.other`: Czech takes all three, and a
    // family that is short one silently falls back across languages.
    const families = new Set(
      keys
        .filter((k) => /\.(one|few|other)$/.test(k))
        .map((k) => k.replace(/\.(one|few|other)$/, "")),
    );
    expect(families.size).toBeGreaterThan(0);
    for (const f of families) {
      for (const form of ["one", "few", "other"]) {
        expect(keys, `${f}.${form}`).toContain(`${f}.${form}`);
        for (const [name, table] of Object.entries(OTHERS)) {
          expect(Object.keys(table), `${name} ${f}.${form}`).toContain(`${f}.${form}`);
        }
      }
    }
  });
});

describe("the locale list", () => {
  it("names all six, each with a label in its own script", () => {
    expect(LOCALES.map((l) => l.id)).toEqual(["en", "ko", "yue", "zh", "ja", "cs"]);
    for (const l of LOCALES) expect(l.label.length).toBeGreaterThan(0);
  });

  it("asks for the CJK face exactly where one is needed", () => {
    // English and Czech are covered by Press Start 2P and VT323 — verified
    // against both fonts' `cmap` tables, upper case and lower, diacritics
    // included — so they must not pull a 6.4 MB face they do not use. The
    // other direction matters more than it looks: the Noto subset does *not*
    // carry `č` or `ř`, so a Czech that reached for it would be half-drawn.
    const need = LOCALES.filter((l) => l.font !== null).map((l) => l.id);
    expect(need).toEqual(["ko", "yue", "zh", "ja"]);
    // One face, one family name, one download, shared by all four.
    const families = new Set(LOCALES.map((l) => l.font?.family).filter(Boolean));
    expect([...families]).toEqual(["NotoSansCJK"]);
    for (const l of LOCALES) {
      if (!l.font) continue;
      expect(l.font.file).toMatch(/^\/fonts\/noto-sans-cjk\/.*\.woff2$/);
    }
  });
});

describe("lookup", () => {
  it("substitutes named placeholders and leaves unknown ones alone", async () => {
    await setLocale("en", false);
    expect(t("app.language", { name: "한국어" })).toBe("language: 한국어");
    expect(t("quest.fontSize", {})).toContain("{percent}");
  });

  it("falls back to English rather than to a blank", async () => {
    await setLocale("cs", false);
    // Every key is present in every table, so this is really a check that the
    // lookup path returns a non-empty string for all of them in all six.
    for (const l of LOCALES) {
      await setLocale(l.id, false);
      for (const k of keys) expect(t(k), `${l.id}/${k}`).not.toBe("");
    }
    await setLocale("en", false);
  });

  it("picks the Czech plural forms apart and folds the CJK ones together", async () => {
    await setLocale("cs", false);
    const one = tn("quest.hintsLeft", 1);
    const few = tn("quest.hintsLeft", 3);
    const many = tn("quest.hintsLeft", 7);
    expect(one).not.toBe(few);
    expect(few).not.toBe(many);
    expect(one).toContain("1");

    await setLocale("ja", false);
    expect(tn("quest.hintsLeft", 1)).toBe(tn("quest.hintsLeft", 7).replace("7", "1"));
    await setLocale("en", false);
    expect(locale()).toBe("en");
  });
});

/**
 * The DOM side of a language change.
 *
 * Canvas text needs no help: every frame re-reads `t()`, so a screen is in the
 * new language by the next draw. A placeholder on a real `<input>` is a string
 * copied once, and it stayed in whatever language was loaded when the field was
 * built — the game shipped with an English interface whose seed-phrase field
 * still read 열두 단어. These are the keys that reach the DOM that way.
 */
describe("a language change reaches strings held in the DOM", () => {
  const HELD_IN_DOM = [
    "login.fieldHint",
    "search.placeholder",
    "pg.stdinHint",
  ] as const;

  // Presence only, deliberately. `search.placeholder` is "borrow checker" in
  // Czech too, because that is what a Czech Rust programmer calls it — a value
  // matching English is a translator's decision here, not a missing key.
  it("every DOM-held hint has a value in all six languages", () => {
    for (const key of HELD_IN_DOM) {
      for (const [name, table] of Object.entries(OTHERS)) {
        expect(table[key], `${name} is missing ${key}`).toBeTruthy();
      }
    }
  });

  it("onLocale fires on a change, so a cached placeholder can be re-read", async () => {
    await setLocale("en", false);
    // Exactly what a scene does: copy the string once, then keep it current.
    let placeholder = t("login.fieldHint");
    const off = onLocale(() => {
      placeholder = t("login.fieldHint");
    });

    await setLocale("ko", false);
    expect(placeholder).toBe(ko["login.fieldHint"]);
    await setLocale("en", false);
    expect(placeholder).toBe(en["login.fieldHint"]);

    // And stops when the scene leaves, or the set retains dead scenes and the
    // detached elements they point at.
    off();
    await setLocale("ja", false);
    expect(placeholder).toBe(en["login.fieldHint"]);
  });

  it("fires synchronously, before the font resolves", async () => {
    await setLocale("en", false);
    let seen = "";
    const off = onLocale(() => (seen = t("login.fieldHint")));
    // No await: the strings are the new language on the call itself, which is
    // what lets the boot screen put the right words up immediately.
    void setLocale("ko", false);
    expect(seen).toBe(ko["login.fieldHint"]);
    off();
    await setLocale("en", false);
  });
});
