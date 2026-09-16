/**
 * One session per tab.
 *
 * The token used to live in `localStorage` under a single key, and
 * `localStorage` belongs to the origin rather than to the tab. So signing in as
 * account 0 in one tab and account 1 in another wrote one key twice: the newest
 * login won and both tabs resumed as it. Two accounts side by side is what the
 * account index was added for, and it did not work.
 *
 * `sessionStorage` is per tab and survives a reload, which is exactly "who this
 * tab is".
 *
 * **Sharing one token between tabs is not merely untidy, it is broken**, and
 * that is what decided the design here. `auth.resume` *rotates*
 * (`auth::rotate_session`): it retires the token it was given and issues a
 * fresh one. Two tabs holding one token means the first to reload retires the
 * other's copy, and the other is silently signed out at its next reload. The
 * old shared key hid this only because both tabs also *read* that key, so the
 * rotation propagated. Split the tabs apart and the hazard becomes visible —
 * which is how it was found here, by two tabs and a reload.
 *
 * So a token is never shared, and a new tab signs in for itself. The cost is
 * real and worth stating: opening a new tab asks for the recovery phrase
 * again, because there is nothing safe to carry over. The phrase itself is
 * never stored (SPEC §3.1) and that is not up for negotiation.
 *
 * The one exception is the upgrade. A token left in `localStorage` by the old
 * build is **claimed by the first tab that asks and removed from the shared
 * store in the same breath**, so exactly one tab inherits the session and
 * nobody is signed out by installing this. After that the shared key is gone
 * and never written again.
 *
 * Every access is wrapped: in private browsing, or with site data blocked,
 * touching either store throws. A game that cannot save a session is still a
 * game; it degrades to "you are signed out", never to a blank screen.
 */
export type StorageLike = Pick<Storage, "getItem" | "setItem" | "removeItem">;

/** Whatever this browser gives us, or nothing, without ever throwing. */
function safe(get: () => Storage | null | undefined): StorageLike | null {
  try {
    const store = get();
    if (!store) return null;
    // Touch it once here rather than discovering at the first login that the
    // store exists as an object and throws on use, which is what Safari does
    // with site data blocked.
    const probe = "cwbhacker.probe";
    store.setItem(probe, "1");
    store.removeItem(probe);
    return store;
  } catch {
    return null;
  }
}

const read = (store: StorageLike | null, key: string): string | null => {
  try {
    return store?.getItem(key) ?? null;
  } catch {
    return null;
  }
};
const write = (store: StorageLike | null, key: string, value: string): void => {
  try {
    store?.setItem(key, value);
  } catch {
    /* a session that cannot be saved is not a session that cannot be used */
  }
};
const drop = (store: StorageLike | null, key: string): void => {
  try {
    store?.removeItem(key);
  } catch {
    /* as above */
  }
};

/**
 * Build the storage the client keeps its token in.
 *
 * Takes both stores rather than reaching for the globals, so the rule above
 * can be tested without a browser.
 */
export function tabSession(
  sessionStore: StorageLike | null,
  localStore: StorageLike | null,
): StorageLike {
  /**
   * This tab signed out, as distinct from never having signed in.
   *
   * Without it the two look identical, and the next read would claim the
   * legacy token again — so signing out would not stick across a reload.
   */
  const OUT = (key: string) => `${key}.signedout`;

  return {
    getItem(key: string): string | null {
      const mine = read(sessionStore, key);
      if (mine !== null) return mine;
      if (read(sessionStore, OUT(key)) !== null) return null;
      // The upgrade path, once. Claimed *and* removed together: two tabs both
      // inheriting it would be the rotation collision described above, with
      // the loser signed out at its next reload.
      const legacy = read(localStore, key);
      if (legacy === null) return null;
      drop(localStore, key);
      write(sessionStore, key, legacy);
      return legacy;
    },

    setItem(key: string, value: string): void {
      drop(sessionStore, OUT(key));
      write(sessionStore, key, value);
      // Deliberately not written to the shared store. That is the whole fix.
    },

    removeItem(key: string): void {
      drop(sessionStore, key);
      write(sessionStore, OUT(key), "1");
      // Any legacy token still lying about goes too, so signing out cannot be
      // undone by a stale key from before the upgrade.
      drop(localStore, key);
    },
  };
}

/** The same, wired to this browser. Safe where either store is unavailable. */
export function browserTabSession(): StorageLike {
  return tabSession(
    safe(() => globalThis.sessionStorage),
    safe(() => globalThis.localStorage),
  );
}
