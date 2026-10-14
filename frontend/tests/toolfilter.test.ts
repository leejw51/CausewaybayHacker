import { describe, expect, it } from "vitest";
import { filterKeeps, filterWords } from "../src/ui/toolfilter";

const run = { id: "run", label: "RUN" };
const copyCode = { id: "copycode", label: "코드 복사" };
const paste = { id: "pastecode", label: "붙여넣기" };
const fontUp = { id: "fontup", label: "가+" };

describe("the toolbar filter", () => {
  it("keeps every button when nothing is typed", () => {
    for (const q of ["", "   ", " , "]) expect(filterKeeps(q, fontUp)).toBe(true);
  });

  it("matches one word against the label or the id", () => {
    expect(filterKeeps("copy", copyCode)).toBe(true);
    expect(filterKeeps("복사", copyCode)).toBe(true);
    expect(filterKeeps("copy", run)).toBe(false);
  });

  it("keeps a button that matches any of several words", () => {
    const q = "run copy 붙여";
    expect(filterKeeps(q, run)).toBe(true);
    expect(filterKeeps(q, copyCode)).toBe(true);
    expect(filterKeeps(q, paste)).toBe(true);
    expect(filterKeeps(q, fontUp)).toBe(false);
  });

  it("splits on spaces and every comma a keyboard types", () => {
    expect(filterWords(" Run,copy，paste、font  ")).toEqual(["run", "copy", "paste", "font"]);
  });
});

describe("the toolbar filter, symbolically", () => {
  const all = [
    { id: "run", label: "실행" },
    { id: "autorun", label: "자동 실행 켬" },
    { id: "copycode", label: "코드 복사" },
    { id: "pastecode", label: "붙여넣기" },
    { id: "fontup", label: "가+" },
    { id: "fontdown", label: "가-" },
    { id: "face", label: "DUNGGEUNMO" },
    { id: "theme", label: "다크" },
    { id: "agent", label: "에이전트" },
    { id: "save", label: "저장" },
    { id: "back", label: "지도" },
    { id: "rust", label: "RUST" },
    { id: "go", label: "GO" },
  ];
  const kept = (q: string) => all.filter((b) => filterKeeps(q, b)).map((b) => b.id);

  it("finds a concept by a word the label never says", () => {
    expect(kept("글꼴")).toEqual(["fontup", "fontdown", "face"]);
    expect(kept("font")).toEqual(["fontup", "fontdown", "face"]);
    expect(kept("ai")).toEqual(["agent"]);
    expect(kept("clipboard")).toEqual(["copycode", "pastecode"]);
    expect(kept("나가기")).toEqual(["back"]);
    expect(kept("언어")).toEqual(["rust", "go"]);
  });

  it("finds Korean labels by their initials", () => {
    expect(kept("ㅂㅅ")).toEqual(["copycode"]);
    expect(kept("ㅈㅈ")).toEqual(["save"]);
  });

  it("finds an id by its abbreviation", () => {
    expect(kept("cpcd")).toEqual(["copycode"]);
  });

  it("takes away with a leading minus", () => {
    expect(kept("-font").length).toBe(all.length - 3);
    expect(kept("실행 -auto")).toEqual(["run"]);
  });

  it("puts a working set together from mixed words", () => {
    expect(kept("실행 ㅂㅅ 붙여 글꼴")).toEqual([
      "run",
      "autorun",
      "copycode",
      "pastecode",
      "fontup",
      "fontdown",
      "face",
    ]);
  });
});
