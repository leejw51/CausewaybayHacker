/**
 * The shelf, and the sockets that are the reason it is a shelf.
 *
 * `stats.awards` (§4.14b) returns only what a player *has*, so a screen built
 * from the response alone shows a new player nothing — and nothing reads as
 * "this is not for you". DESIGN drew `badge_slot`, an empty recessed socket,
 * precisely so that an unearned badge reads as a thing you can go and get. That
 * makes the client-side catalogue load-bearing, which makes it worth testing:
 * a slot that stopped matching its award would draw an empty socket next to the
 * badge the player already owns.
 *
 * The id→family mapping is string work over three open-ended prefixes
 * (`tamed-<kind>`, `level-<n>`, `cleared-<land>-<category>`) and sixteen exact
 * ids, and the case that matters most is the one nobody plans for: an award
 * this client has never heard of. The server is designed to grow the set, so an
 * unknown id has to draw *something* — a shelf that dropped an award it could
 * not name would hide the player's own achievement behind an out-of-date
 * client.
 */
import { describe, expect, it } from "vitest";
import type { Award } from "../src/net/protocol";
import { badgeArt, shelf, shelfCount } from "../src/ui/awards";

const award = (id: string, title = id.toUpperCase()): Award => ({
  kind: "badge",
  id,
  title,
  detail: {},
  created_at: "2026-09-11T07:00:01Z",
});

describe("which badge an award wears", () => {
  it("gives each family its own shape", () => {
    expect(badgeArt("first-clear")).toBe("badge_stamp");
    expect(badgeArt("perfectionist")).toBe("badge_star");
    expect(badgeArt("beat-the-clock")).toBe("badge_watch");
    expect(badgeArt("polyglot")).toBe("badge_flags");
    expect(badgeArt("century")).toBe("badge_tally");
  });

  it("gives the tiers within a family their own picture where one exists", () => {
    expect(badgeArt("streak-3")).toBe("badge_flame");
    expect(badgeArt("streak-7")).toBe("badge_flame_7");
    expect(badgeArt("streak-30")).toBe("badge_flame_30");
    expect(badgeArt("combo-5")).toBe("badge_chain");
    expect(badgeArt("combo-25")).toBe("badge_chain_25");
  });

  it("reads the three open-ended families off their prefix", () => {
    expect(badgeArt("tamed-borrow-after-move")).toBe("badge_shackle");
    expect(badgeArt("level-4")).toBe("badge_chevron");
    expect(badgeArt("level-37")).toBe("badge_chevron");
    expect(badgeArt("cleared-rust-basic")).toBe("badge_cleared");
  });

  it("never returns nothing for an id it has not heard of", () => {
    expect(badgeArt("something-the-server-added-later")).toBe("badge_stamp");
    expect(badgeArt("")).toBe("badge_stamp");
    // A bare prefix with nothing after it is not a member of that family.
    expect(badgeArt("tamed-")).toBe("badge_stamp");
    expect(badgeArt("level-")).toBe("badge_stamp");
  });
});

describe("the shelf", () => {
  it("is all sockets and no badges for a new player", () => {
    const slots = shelf([]);
    expect(slots.length).toBeGreaterThan(10);
    expect(slots.every((s) => s.award === null)).toBe(true);
    // Every socket names a thing you could go and do, which is the whole point.
    expect(slots.every((s) => s.title.length > 0 && s.hint.length > 0)).toBe(true);
  });

  it("puts what you have in front of what you have not", () => {
    const slots = shelf([award("polyglot"), award("first-clear")]);
    expect(slots[0].id).toBe("polyglot");
    expect(slots[1].id).toBe("first-clear");
    expect(slots[0].award).not.toBeNull();
    expect(slots.slice(2).every((s) => s.award === null)).toBe(true);
  });

  it("never draws an earned badge as a socket as well", () => {
    const slots = shelf([award("century")]);
    expect(slots.filter((s) => s.id === "century")).toHaveLength(1);
  });

  it("keeps an open-family award with its server-given title", () => {
    const slots = shelf([award("tamed-borrow-after-move", "TAMED: BORROW AFTER MOVE")]);
    expect(slots[0].title).toBe("TAMED: BORROW AFTER MOVE");
    expect(slots[0].art).toBe("badge_shackle");
    // …and does not add a socket for it: there is no fixed number of them.
    expect(slots.filter((s) => s.art === "badge_shackle")).toHaveLength(1);
  });

  it("falls back to the id when a server sends no title", () => {
    const bare = { ...award("level-9"), title: "" };
    expect(shelf([bare])[0].title).toBe("LEVEL-9");
  });

  it("counts only the nameable ones, so the line cannot exceed itself", () => {
    expect(shelfCount([]).have).toBe(0);
    const all = shelfCount([]);
    expect(all.of).toBeGreaterThan(10);
    // An open-family award is not one of the countable sockets.
    expect(shelfCount([award("level-4"), award("tamed-syntax")]).have).toBe(0);
    expect(shelfCount([award("no-hints"), award("level-4")])).toEqual({ have: 1, of: all.of });
  });
});
