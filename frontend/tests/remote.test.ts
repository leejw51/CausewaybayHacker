/**
 * A pad saved on another of this user's devices (PROTOCOL §4.22): when the
 * screen takes it, when it only says so, and when it is not this pad at all.
 */
import { describe, expect, it } from "vitest";
import { remoteSaveAction } from "../src/net/remote";

describe("a save that arrived from another device", () => {
  it("is taken when this pad is clean, said when it is dirty, ignored when it is another pad", () => {
    expect(remoteSaveAction("pg_a", "pg_a", false)).toBe("apply");
    expect(remoteSaveAction("pg_a", "pg_a", true)).toBe("notify");
    expect(remoteSaveAction("pg_a", "pg_b", false)).toBe("ignore");
    expect(remoteSaveAction("pg_a", "pg_b", true)).toBe("ignore");
    // An unsaved pad has no id and can never be the one that was saved.
    expect(remoteSaveAction(null, "pg_a", false)).toBe("ignore");
  });
});
