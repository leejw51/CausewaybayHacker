/**
 * Test-harness shim for Web Storage.
 *
 * Node 25+ exposes `globalThis.localStorage` itself, as a getter that returns
 * `undefined` unless the process was started with `--localstorage-file`, and
 * happy-dom does not replace a property that already exists on the global.
 * `ui/prefs.ts` then swallows `undefined.getItem` as "storage blocked" and
 * every preference reads back as unset — which is correct product behaviour
 * and sixteen wrong tests. CI pins Node 24, where the global is happy-dom's.
 *
 * So: when the global is missing or its getter throws, install a minimal
 * in-memory `Storage` with the real thing's semantics (string coercion of key
 * and value, `null` for a miss, `key(i)` `null` out of range). A working
 * storage — Node 24 in CI, or a future happy-dom that wins the race — is left
 * alone. The product is not touched.
 */

class MemoryStorage implements Storage {
  private map = new Map<string, string>();

  get length(): number {
    return this.map.size;
  }

  key(index: number): string | null {
    return [...this.map.keys()][index] ?? null;
  }

  getItem(key: string): string | null {
    return this.map.get(String(key)) ?? null;
  }

  setItem(key: string, value: string): void {
    this.map.set(String(key), String(value));
  }

  removeItem(key: string): void {
    this.map.delete(String(key));
  }

  clear(): void {
    this.map.clear();
  }
}

function usable(name: "localStorage" | "sessionStorage"): boolean {
  try {
    const s = (globalThis as Record<string, unknown>)[name] as Storage | undefined;
    return s != null && typeof s.getItem === "function";
  } catch {
    return false;
  }
}

for (const name of ["localStorage", "sessionStorage"] as const) {
  if (usable(name)) continue;
  const value = new MemoryStorage();
  try {
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
  } catch {
    delete (globalThis as Record<string, unknown>)[name];
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
  }
}
