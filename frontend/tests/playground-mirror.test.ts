import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * The playground keeps a local mirror of the pad you have open, so text that
 * never reached the server survives a reload. It used to live under one key for
 * the whole origin — and once two tabs could be signed in as two accounts, one
 * account's unsaved draft was restored into the other's playground.
 *
 * It carried `id` with it, a snippet id belonging to somebody else, which the
 * next autosave then tried to save into. The server scopes snippets by address
 * and refuses, so nothing was corrupted; it showed the wrong text and then
 * failed.
 *
 * Driving the real scene would need a canvas, an `App`, a websocket and a
 * CodeMirror instance, none of which would make these any truer: what is being
 * asserted is that the key has the account in it and that nothing reads or
 * writes the mirror without one.
 */
const SOURCE = readFileSync(resolve(process.cwd(), "src/scenes/playground.ts"), "utf8");

describe("the playground's local mirror", () => {
  it("is keyed by the account, not by the origin", () => {
    // A template, so the address is part of the key rather than a prefix
    // somebody could forget to add at one of the seven call sites.
    expect(SOURCE).toMatch(/const LOCAL_KEY = \(address: string\) =>/);
    expect(SOURCE).toContain("address.toLowerCase()");
  });

  it("never touches storage without an account to key it by", () => {
    // Both directions: an unowned draft cannot be written anywhere sensible,
    // and cannot be handed back to anyone safely.
    for (const fn of ["private writeLocal(", "private restoreLocal("]) {
      const body = SOURCE.slice(SOURCE.indexOf(fn));
      const end = body.indexOf("\n  }");
      expect(body.slice(0, end)).toContain("if (!key) return;");
    }
  });

  it("reaches storage only through the keyed helper", () => {
    // The bug was one bare key used everywhere. A raw call with a string
    // literal, in either store, is the same mistake coming back.
    const direct = [...SOURCE.matchAll(/(local|session)Storage\.(get|set)Item\(\s*["'`]/g)];
    expect(direct).toHaveLength(0);
  });

  it("keeps the draft in the tab, beside the session that owns it", () => {
    // `sessionStorage`, so a tab practising as another identity cannot see it,
    // and so it still survives the reload the mirror exists for.
    const write = SOURCE.slice(SOURCE.indexOf("private writeLocal("));
    expect(write.slice(0, write.indexOf("\n  }"))).toContain("sessionStorage.setItem(key,");
    const read = SOURCE.slice(SOURCE.indexOf("private restoreLocal("));
    expect(read.slice(0, read.indexOf("\n  }"))).toContain("sessionStorage.getItem(key)");
  });

  it("uses localStorage for one thing only: deleting the old shared key", () => {
    const calls = [...SOURCE.matchAll(/localStorage\.(\w+)\(/g)].map((m) => m[1]);
    expect(calls).toEqual(["removeItem"]);
  });

  it("drops the old shared key rather than guessing whose draft it was", () => {
    const body = SOURCE.slice(SOURCE.indexOf("private restoreLocal("));
    expect(body.slice(0, body.indexOf("\n  }"))).toContain(
      "localStorage.removeItem(LEGACY_LOCAL_KEY)",
    );
  });
});
