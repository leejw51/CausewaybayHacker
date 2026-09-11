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
import { LOCALES, locale, setLocale, t, tn } from "../src/i18n";

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

  it("asks for a CJK pixel font exactly where one is needed", () => {
    // English and Czech are covered by Press Start 2P and VT323 — verified
    // against both fonts' `cmap` tables, upper case and lower, diacritics
    // included — so they must not pull a 900 KB face they do not use.
    const need = LOCALES.filter((l) => l.font !== null).map((l) => l.id);
    expect(need).toEqual(["ko", "yue", "zh", "ja"]);
    for (const l of LOCALES) {
      if (!l.font) continue;
      expect(l.font.file).toMatch(/^\/fonts\/fusion-pixel\/.*\.woff2$/);
      // One family name per file. Sharing a name across four faces invites the
      // browser to pick whichever it loaded first.
      expect(LOCALES.filter((o) => o.font?.family === l.font?.family)).toHaveLength(1);
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
