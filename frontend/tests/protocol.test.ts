// A land is a place; a language is what compiles. REMIX LAND is where the two
// stop being the same word, and `questLang` is the one place a client turns
// a quest into the language its code is in.
import { describe, expect, it } from "vitest";
import { CATEGORIES, LANDS, LANGS, isLand, isLang, isSheet, questLang, roadsOf } from "../src/net/protocol";

describe("lands and languages", () => {
  it("every language is a land, and remix is the one land that is not a language", () => {
    for (const lang of LANGS) expect(isLand(lang)).toBe(true);
    expect(isLand("remix")).toBe(true);
    expect(isLang("remix")).toBe(false);
    expect(LANDS).toEqual([...LANGS, "remix"]);
  });

  it("keeps the lands screen's order: the eight, then remix last", () => {
    expect(LANDS[LANDS.length - 1]).toBe("remix");
    expect(LANGS).toEqual(["rust", "go", "cpp", "python", "pytorch", "typescript", "zig", "lua"]);
  });
});

describe("roadsOf", () => {
  it("gives every land the two sheet roads first, every language land six roads, rust a seventh, and remix four", () => {
    const six = ["cheatsheet", "cheatsheet_advanced", "verybasic", "basic", "advanced", "hacker"];
    for (const lang of LANGS) {
      if (lang === "rust") continue;
      expect(roadsOf(lang)).toEqual(six);
    }
    expect(roadsOf("rust")).toEqual([...six, "frameworks"]);
    expect(roadsOf("rust")).toEqual(CATEGORIES);
    expect(roadsOf("remix")).toEqual(["cheatsheet", "cheatsheet_advanced", "verybasic", "basic"]);
    expect(roadsOf("zig")).toEqual(six);
    expect(roadsOf("lua")).toEqual(six);
    // A land nobody has opened is treated as a language land: six roads.
    expect(roadsOf("cobol")).toEqual(six);
    // CHEATSHEET walks first: the grammar off the page, before it is typed;
    // its ADVANCED half is next, and both are judged without a compiler.
    expect(CATEGORIES[0]).toBe("cheatsheet");
    expect(CATEGORIES[1]).toBe("cheatsheet_advanced");
    expect(isSheet("cheatsheet") && isSheet("cheatsheet_advanced")).toBe(true);
    expect(isSheet("advanced") || isSheet("verybasic")).toBe(false);
    // FRAMEWORKS walks last: it is the job after the interview.
    expect(CATEGORIES[CATEGORIES.length - 1]).toBe("frameworks");
  });
});

describe("questLang", () => {
  it("is the quest's own lang when the server sent one", () => {
    expect(questLang({ land: "remix", lang: "go" })).toBe("go");
    expect(questLang({ land: "remix", lang: "python" })).toBe("python");
    expect(questLang({ land: "rust", lang: "rust" })).toBe("rust");
  });

  it("is the land on a server too old to send lang, since there the land is the language", () => {
    for (const lang of LANGS) expect(questLang({ land: lang })).toBe(lang);
  });

  it("never answers remix, and never trusts a lang it does not know", () => {
    expect(questLang({ land: "remix" })).toBe("rust");
    // `zig` was the unknown here until ZIG LAND opened; COBOL can wait.
    expect(questLang({ land: "go", lang: "cobol" })).toBe("go");
    expect(questLang({ land: "cobol" })).toBe("rust");
    expect(questLang({ land: "zig" })).toBe("zig");
    expect(questLang({ land: "remix", lang: "lua" })).toBe("lua");
  });
});
