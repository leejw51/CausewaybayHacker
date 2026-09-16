import { beforeEach, describe, expect, it } from "vitest";
import { tabSession, type StorageLike } from "../src/net/tabsession";

/** A store that behaves like one, so the rule can be tested without a browser. */
function store(): StorageLike & { map: Map<string, string> } {
  const map = new Map<string, string>();
  return {
    map,
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => void map.set(k, v),
    removeItem: (k) => void map.delete(k),
  };
}

/** One that throws on every access, the way Safari does with site data off. */
const hostile: StorageLike = {
  getItem() {
    throw new Error("site data is blocked");
  },
  setItem() {
    throw new Error("site data is blocked");
  },
  removeItem() {
    throw new Error("site data is blocked");
  },
};

const KEY = "cwbhacker.token";

describe("one session per tab", () => {
  let shared: ReturnType<typeof store>;
  beforeEach(() => {
    shared = store();
  });

  /** A tab: its own `sessionStorage` over the one shared `localStorage`. */
  const tab = () => tabSession(store(), shared);

  it("has no session before anything has signed in", () => {
    expect(tab().getItem(KEY)).toBeNull();
  });

  it("keeps two tabs on two accounts, which is the bug this fixes", () => {
    const a = tab();
    a.setItem(KEY, "token-index-0");
    const b = tab();
    b.setItem(KEY, "token-index-1");

    expect(a.getItem(KEY)).toBe("token-index-0");
    expect(b.getItem(KEY)).toBe("token-index-1");
  });

  it("never puts a token in the shared store", () => {
    // The heart of it. `auth.resume` rotates — it retires the token it is
    // given — so two tabs holding one token means the first to reload signs
    // the other out. Nothing may be shared for a second tab to pick up.
    tab().setItem(KEY, "token-a");
    expect(shared.map.get(KEY)).toBeUndefined();
  });

  it("makes a new tab sign in for itself rather than inherit a live session", () => {
    const a = tab();
    a.setItem(KEY, "token-a");
    // The cost of the fix, asserted so nobody restores the old behaviour by
    // accident: a tab opened now is signed out, not silently signed in as A.
    expect(tab().getItem(KEY)).toBeNull();
  });

  it("signing out of one tab does not touch the other", () => {
    const a = tab();
    a.setItem(KEY, "token-a");
    const b = tab();
    b.setItem(KEY, "token-b");

    b.removeItem(KEY);
    expect(b.getItem(KEY)).toBeNull();
    expect(a.getItem(KEY)).toBe("token-a");
  });

  it("stays signed out across a reload of the same tab", () => {
    // `sessionStorage` survives a reload, so "I signed out" has to survive it
    // too — otherwise the next read claims a leftover token and signs you
    // back in.
    const session = store();
    shared.map.set(KEY, "legacy-token");
    const a = tabSession(session, shared);
    a.removeItem(KEY);
    // The same tab, after a reload: same sessionStorage, new wrapper.
    expect(tabSession(session, shared).getItem(KEY)).toBeNull();
  });

  describe("upgrading from the shared-token build", () => {
    it("lets exactly one tab inherit the old session", () => {
      shared.map.set(KEY, "legacy-token");
      const first = tab();
      // Nobody is signed out by installing the new build…
      expect(first.getItem(KEY)).toBe("legacy-token");
      // …and it is gone from the shared store in the same breath, so a second
      // tab cannot inherit it too and retire the first tab's token by
      // resuming with it.
      expect(shared.map.get(KEY)).toBeUndefined();
      expect(tab().getItem(KEY)).toBeNull();
    });

    it("keeps the inherited token across that tab's reloads", () => {
      shared.map.set(KEY, "legacy-token");
      const session = store();
      expect(tabSession(session, shared).getItem(KEY)).toBe("legacy-token");
      expect(tabSession(session, shared).getItem(KEY)).toBe("legacy-token");
    });
  });

  it("works when there is no per-tab store at all", () => {
    const only = tabSession(null, shared);
    expect(() => only.setItem(KEY, "token-a")).not.toThrow();
    // Nothing can be remembered without somewhere per-tab to remember it, and
    // "signed out" is the safe answer rather than "signed in as whoever".
    expect(only.getItem(KEY)).toBeNull();
  });

  it("never throws when the browser refuses storage", () => {
    const blocked = tabSession(hostile, hostile);
    expect(() => blocked.setItem(KEY, "token")).not.toThrow();
    expect(blocked.getItem(KEY)).toBeNull();
    expect(() => blocked.removeItem(KEY)).not.toThrow();
  });
});
