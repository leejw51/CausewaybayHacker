/**
 * Small, boring, survivable preferences.
 *
 * Everything a player *chooses about how the game looks* goes through here:
 * the orientation pin already had its own pair of try/catch blocks in `app.ts`
 * and every new preference was about to grow another one. A browser with
 * storage blocked (private window, a locked-down profile, a file:// page) must
 * still run — the choice simply lasts for the session instead of for ever —
 * so every read and every write is guarded and a failure is silent by design.
 *
 * Nothing secret goes through here. Key material is `wallet/wallet.ts`'s
 * business, which keeps its own slot and does its own reading (SPEC §3.1).
 */

/** One namespace, so a stray key in devtools is obviously ours. */
const NS = "cwbhacker.";

export function readPref(key: string): string | null {
  try {
    return localStorage.getItem(NS + key);
  } catch {
    return null;
  }
}

export function writePref(key: string, value: string): void {
  try {
    localStorage.setItem(NS + key, value);
  } catch {
    /* the choice still holds for this session */
  }
}

/** A number within bounds, or the fallback. Never NaN, never out of range. */
export function readNumberPref(key: string, fallback: number, lo: number, hi: number): number {
  const raw = readPref(key);
  if (raw === null) return fallback;
  const n = Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(hi, Math.max(lo, n));
}

/** One of a fixed set, or the fallback. Guards against a hand-edited value. */
export function readEnumPref<T extends string>(key: string, allowed: readonly T[], fallback: T): T {
  const raw = readPref(key);
  return (allowed as readonly string[]).includes(raw ?? "") ? (raw as T) : fallback;
}
