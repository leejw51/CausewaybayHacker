/**
 * The counter that is the product, and the four screens that have no rows.
 *
 * SPEC §7.2's `cleared_since` is drawn as five pips and a sentence, and it is
 * the only number in this game that is *about the player rather than about a
 * quest*. Off by one in either direction and the shelf's `tamed-<kind>` badge
 * fires at a moment the screen said had not arrived, so the arithmetic is
 * pinned here rather than trusted to a drawing routine.
 *
 * The empty states matter for a different reason: they are the only part of
 * this feature a brand new player can see, and there is no way to reach three
 * of them by hand today — `ai.plan` answers `unavailable` on the live server, so
 * a plan that comes back empty cannot be produced to look at. A test is the
 * only verification route there is.
 */
import { describe, expect, it } from "vitest";
import type { MistakeStat } from "../src/net/protocol";
import {
  drillHeadline,
  emptyDrill,
  emptySearch,
  isLearned,
  LEARNED_AT,
  tamedFraction,
  tamedLine,
} from "../src/ui/coach";

const stat = (kind: string, count: number, cleared_since: number): MistakeStat => ({
  kind,
  label: kind.replace(/-/g, " "),
  count,
  last_at: "2026-09-11T07:00:01Z",
  cleared_since,
  example_quest_id: "rust.basic.01.first-light",
  concepts: ["bindings"],
});

describe("progress towards learned", () => {
  it("is five, because §7.2 says five", () => {
    expect(LEARNED_AT).toBe(5);
  });

  it("walks 0 → 1 over the five submits and stops there", () => {
    expect(tamedFraction({ cleared_since: 0 })).toBe(0);
    expect(tamedFraction({ cleared_since: 1 })).toBeCloseTo(0.2, 6);
    expect(tamedFraction({ cleared_since: 4 })).toBeCloseTo(0.8, 6);
    expect(tamedFraction({ cleared_since: 5 })).toBe(1);
    // A kind is not deleted when it is learned (§7.2), so the counter keeps
    // climbing and the bar must not run off the end of the row.
    expect(tamedFraction({ cleared_since: 97 })).toBe(1);
  });

  it("treats rubbish as no progress rather than as some", () => {
    expect(tamedFraction({ cleared_since: -3 })).toBe(0);
    expect(tamedFraction({ cleared_since: Number.NaN })).toBe(0);
  });

  it("crosses into learned at exactly five", () => {
    expect(isLearned({ cleared_since: 4 })).toBe(false);
    expect(isLearned({ cleared_since: 5 })).toBe(true);
  });

  it("counts down in submits, forwards, in words", () => {
    expect(tamedLine({ cleared_since: 0 })).toBe("MADE IT ON YOUR LAST SUBMIT");
    expect(tamedLine({ cleared_since: 1 })).toBe("1 CLEAN SUBMIT SINCE — 4 TO GO");
    expect(tamedLine({ cleared_since: 4 })).toBe("4 CLEAN SUBMITS SINCE — 1 TO GO");
    expect(tamedLine({ cleared_since: 5 })).toBe("LEARNED — OFF THE DRILL");
    expect(tamedLine({ cleared_since: 12 })).toBe("LEARNED — OFF THE DRILL");
  });
});

describe("the drill headline", () => {
  it("names the worst kind still standing, not the worst kind", () => {
    const mistakes = [
      stat("wrong-answer", 9, 5), // beaten, however often it happened
      stat("borrow-after-move", 6, 1),
      stat("syntax", 2, 0),
    ];
    expect(drillHeadline(mistakes)).toBe("BORROW AFTER MOVE — 6×");
  });

  it("says so when there is nothing on it", () => {
    expect(drillHeadline([])).toBe("NOTHING IS ON THE DRILL");
    expect(drillHeadline([stat("syntax", 3, 5)])).toBe("NOTHING IS ON THE DRILL");
  });
});

describe("an empty drill says which kind of empty", () => {
  const fresh = { live: 0, learned: 0, cleared: 0, attempts: 0 };

  it("meets a brand new player before it blames a mode", () => {
    // A player with no attempts at all gets the same answer for all three,
    // because the reason is the same one and it is not about the mode.
    const heads = new Set(
      (["repeat", "weakness", "spaced"] as const).map((m) => emptyDrill(m, fresh).head),
    );
    expect(heads.size).toBe(1);
    expect([...heads][0]).toBe("THE COACH HAS NOT MET YOU YET");
  });

  it("gives each mode its own reason once there is a record", () => {
    const busy = { live: 0, learned: 0, cleared: 3, attempts: 40 };
    const heads = (["repeat", "weakness", "spaced"] as const).map((m) => emptyDrill(m, busy).head);
    expect(new Set(heads).size).toBe(3);
  });

  it("tells a player who has beaten everything that they have", () => {
    const won = { live: 0, learned: 4, cleared: 12, attempts: 60 };
    const none = { live: 0, learned: 0, cleared: 12, attempts: 60 };
    expect(emptyDrill("weakness", won).head).toBe("NO WEAK SPOT LEFT");
    expect(emptyDrill("weakness", won).body).toContain("4 mistake kinds");
    expect(emptyDrill("weakness", none).head).toBe("NO WEAK SPOT YET");
  });

  it("separates 'nothing cleared' from 'nothing due' for spaced review", () => {
    expect(emptyDrill("spaced", { live: 1, learned: 0, cleared: 0, attempts: 9 }).head).toBe(
      "NOTHING TO COME BACK TO",
    );
    expect(emptyDrill("spaced", { live: 1, learned: 0, cleared: 7, attempts: 9 }).head).toBe(
      "NOTHING IS DUE",
    );
  });

  it("always offers somewhere to go", () => {
    for (const mode of ["repeat", "weakness", "spaced"] as const) {
      for (const ctx of [fresh, { live: 0, learned: 2, cleared: 5, attempts: 30 }]) {
        const empty = emptyDrill(mode, ctx);
        expect(empty.action.length).toBeGreaterThan(0);
        expect(empty.body.length).toBeGreaterThan(20);
      }
    }
  });
});

describe("an empty search box is not a failed search", () => {
  it("invites, rather than reporting nothing found", () => {
    const idle = emptySearch("", false);
    expect(idle.head).toBe("ONE BOX, 126 STREETS");
    expect(idle.body).not.toContain("Nothing");
  });

  it("reports nothing found only once something was asked", () => {
    expect(emptySearch("zzz", false).head).toBe("READY");
    const missed = emptySearch("zzz", true);
    expect(missed.head).toBe("NOTHING MATCHED");
    expect(missed.body).toContain("zzz");
  });

  it("ignores a box holding only whitespace", () => {
    // §4.12: an empty `q` returns no hits rather than everything, so a box with
    // three spaces in it has not asked a question.
    expect(emptySearch("   ", true).head).toBe("ONE BOX, 126 STREETS");
  });
});
