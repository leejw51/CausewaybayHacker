import { describe, expect, it } from "vitest";
import { readToday, recordRun, streak, type Store } from "../src/ui/today";

const mem = (): Store => {
  const m = new Map<string, string>();
  return { get: (k) => m.get(k) ?? null, set: (k, v) => void m.set(k, v) };
};
const at = (d: string) => new Date(`${d}T12:00:00`);

describe("today at the bench", () => {
  it("counts runs, fixes and languages, and starts over the next day", () => {
    const s = mem();
    recordRun(s, at("2026-11-16"), "rust", false);
    recordRun(s, at("2026-11-16"), "rust", true);
    const t = recordRun(s, at("2026-11-16"), "go", false);
    expect(t).toEqual({ date: "2026-11-16", runs: 3, fixes: 1, langs: ["rust", "go"] });
    expect(readToday(s, at("2026-11-17"))).toEqual({
      date: "2026-11-17",
      runs: 0,
      fixes: 0,
      langs: [],
    });
  });

  it("counts a streak of days in a row, still alive the morning after", () => {
    const s = mem();
    for (const d of ["2026-11-12", "2026-11-14", "2026-11-15", "2026-11-16"])
      recordRun(s, at(d), "rust", false);
    expect(streak(s, at("2026-11-16"))).toBe(3);
    expect(streak(s, at("2026-11-17"))).toBe(3);
    expect(streak(s, at("2026-11-18"))).toBe(0);
  });
});
