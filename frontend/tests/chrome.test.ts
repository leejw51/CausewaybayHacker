/**
 * Two pieces of shared chrome that broke when the game grew.
 *
 * **`landName`** — the category panel beside a C++ plate read `CPP`, because
 * the title was `land.toUpperCase()` and that is right for three of the four
 * lands and wrong for the one whose name has punctuation in it. Nobody calls
 * the language CPP.
 *
 * **`askHeight`** — the confirmation dialogue was a flat 190px, which holds two
 * lines of English. The Korean "clear the stack?" body wraps to four and the
 * last two printed underneath the buttons, so the sentence explaining what was
 * about to be destroyed was the part you could not read. It failed only in the
 * languages the people writing it do not read, which is the kind of bug a test
 * has to catch because a glance will not.
 */
import { describe, expect, it } from "vitest";
import { askHeight } from "../src/app";
import { landColour, landName, RUST } from "../src/ui/chrome";
import { LANDS } from "../src/net/protocol";
import { setLocale } from "../src/i18n";

describe("landName", () => {
  it("writes C++ as C++, not as CPP", () => {
    setLocale("en", false);
    expect(landName("cpp")).toBe("C++");
  });

  it("gives every land a name that is not its bare identifier", () => {
    setLocale("en", false);
    for (const land of LANDS) {
      const name = landName(land);
      expect(name.length).toBeGreaterThan(0);
      // `cpp` must not leak through as itself; the others upper-case to
      // themselves and that is fine.
      if (land === "cpp") expect(name).not.toBe("cpp");
    }
  });

  it("keeps the land names in English in every locale, like RUST and GO", () => {
    // They are names, not words. A Korean player sees C++ and PYTHON too.
    for (const locale of ["en", "ko", "ja", "zh", "yue", "cs"] as const) {
      setLocale(locale, false);
      expect(landName("cpp")).toBe("C++");
      expect(landName("rust")).toBe("RUST");
    }
    setLocale("en", false);
  });

  it("falls back rather than throwing on a land it has never heard of", () => {
    expect(() => landName("brainfuck")).not.toThrow();
    expect(landColour("brainfuck")).toEqual(RUST);
  });
});

describe("landColour", () => {
  it("gives each of the four lands its own colour", () => {
    const seen = LANDS.map((l) => landColour(l).join(","));
    expect(new Set(seen).size).toBe(LANDS.length);
  });
});

describe("askHeight", () => {
  /** The real numbers at scale 1: body starts at 56, lines are 16, buttons 40. */
  const at = (lines: number) => askHeight(1, 56, lines, 16, 40);

  it("keeps the old height for the short English questions it was tuned on", () => {
    expect(at(1)).toBe(190);
    expect(at(2)).toBe(190);
  });

  it("grows once the body is taller than the old fixed height", () => {
    expect(at(5)).toBeGreaterThan(190);
  });

  it("grows by exactly one line per line", () => {
    expect(at(6) - at(5)).toBe(16);
  });

  it("always leaves the buttons room below the body — the actual bug", () => {
    // The failure was the last lines of the body printing *under* the buttons.
    // Whatever the body, the panel must still hold the body, the buttons and
    // the skirt beneath them.
    for (const lines of [1, 2, 3, 4, 6, 10, 20]) {
      const h = askHeight(1, 56, lines, 16, 40);
      const bodyBottom = 56 + lines * 16;
      const buttonTop = h - 40 - 18;
      expect(buttonTop).toBeGreaterThanOrEqual(bodyBottom);
    }
  });

  it("holds at every type step, not just the default one", () => {
    for (const s of [1, 1.5, 2, 2.5, 3]) {
      const bodyTop = Math.round(56 * s);
      const lineH = Math.round(16 * s);
      const buttonH = Math.round(40 * s);
      for (const lines of [1, 4, 8]) {
        const h = askHeight(s, bodyTop, lines, lineH, buttonH);
        const buttonTop = h - buttonH - Math.round(18 * s);
        expect(buttonTop).toBeGreaterThanOrEqual(bodyTop + lines * lineH);
      }
    }
  });

  it("never returns something smaller than the floor", () => {
    expect(askHeight(1, 0, 0, 0, 0)).toBe(190);
  });
});
