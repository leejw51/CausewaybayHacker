// A land is a place; a language is what compiles. REMIX LAND is where the two
// stop being the same word, and `questLang` is the one place a client turns
// a quest into the language its code is in.
import { describe, expect, it } from "vitest";
import { CATEGORIES, isLand, isLang, LANDS, LANGS, questLang, roadsOf } from "../src/net/protocol";

describe("lands and languages", () => {
  it("every language is a land, and remix is the one land that is not a language", () => {
    for (const lang of LANGS) expect(isLand(lang)).toBe(true);
    expect(isLand("remix")).toBe(true);
    expect(isLang("remix")).toBe(false);
    expect(LANDS).toEqual([...LANGS, "remix"]);
  });

  it("keeps the lands screen's order: the six, then remix last", () => {
    expect(LANDS[LANDS.length - 1]).toBe("remix");
    expect(LANGS).toEqual(["rust", "go", "cpp", "python", "pytorch", "typescript"]);
  });
});

describe("roadsOf", () => {
  it("gives every language land the four roads and remix the two grammar roads", () => {
    for (const lang of LANGS) expect(roadsOf(lang)).toEqual(CATEGORIES);
    expect(roadsOf("remix")).toEqual(["verybasic", "basic"]);
    expect(roadsOf("zig")).toEqual(CATEGORIES);
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
    expect(questLang({ land: "go", lang: "zig" })).toBe("go");
    expect(questLang({ land: "zig" })).toBe("rust");
  });
});
